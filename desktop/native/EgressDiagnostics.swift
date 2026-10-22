import Foundation
import CryptoKit
import Darwin

enum EgressProbeKind: String, CaseIterable, Identifiable, Codable {
    case terminal, claude, proxy, ipv4, ipv6, browser
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: return "默认 curl"
        case .claude: return "Claude 配置模拟"
        case .proxy: return "自定义代理"
        case .ipv4: return "IPv4 · 不指定代理"
        case .ipv6: return "IPv6 · 不指定代理"
        case .browser: return "纯净浏览器"
        }
    }
    var detail: String {
        switch self {
        case .terminal: return "读取 curl 默认配置，继承 App 启动环境"
        case .claude: return "按 Claude 全局代理配置请求，不调用模型"
        case .proxy: return "仅在自定义代理开关开启时，使用指定地址请求"
        case .ipv4: return "忽略显式代理；仍可能由 TUN 接管"
        case .ipv6: return "忽略显式代理；用于发现 IPv6 旁路"
        case .browser: return "使用设置中的浏览器引擎和代理设置；临时空白资料目录，不携带登录态"
        }
    }
    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .claude: return "gearshape"
        case .proxy: return "arrow.triangle.branch"
        case .ipv4: return "4.circle"
        case .ipv6: return "6.circle"
        case .browser: return "globe"
        }
    }
}

struct EgressProbeResult: Identifiable {
    let kind: EgressProbeKind
    var id: String { kind.id }
    var ip: String?
    var country: String?
    var colo: String?
    var tls: String?
    var milliseconds: Int = 0
    var error: String?
    var skippedReason: String?
    var finishedAt = Date()
    var browserName: String?
    var cookiesAtStart: Int?
    var timedOut = false
    var attempts = 1
    var isSuccess: Bool { ip != nil && error == nil }
    var fingerprint: String? { ip.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() } }
    var maskedIP: String {
        guard let ip else { return "—" }
        if ip.contains(":") { return ip.split(separator: ":").prefix(2).joined(separator: ":") + ":…" }
        let parts = ip.split(separator: ".")
        return parts.count == 4 ? "\(parts[0]).*.*.\(parts[3])" : "<隐藏>"
    }
}

enum EgressDiagnosticError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

struct EgressProcessOutput { let code: Int32; let text: String; let timedOut: Bool; let oversized: Bool }
private final class EgressCapturedBytes: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
    var oversized = false
    func append(_ next: Data, process: Process, outputReady: ((String) -> Bool)? = nil) {
        lock.lock()
        if data.count + next.count > 4_000_000 { oversized = true } else { data.append(next) }
        let stop = oversized || (outputReady?(String(data: data, encoding: .utf8) ?? "") ?? false)
        lock.unlock()
        if stop && process.isRunning { process.terminate() }
    }
}

enum EgressLocalDiagnostics {
    static let hosts = ["api.anthropic.com", "claude.ai", "claude.com", "platform.claude.com"]
    /// The only host automatic checks touch: an API host that already sees programmatic clients.
    /// Browser-facing hosts (claude.ai etc.) are only probed by curl on a manual check.
    static let commonHosts = ["api.anthropic.com"]
    static let proxyKeys = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY"]
    static func environment() -> [String: String] {
        let allowed = Set(proxyKeys + ["HOME", "PATH", "LANG", "LC_ALL", "CURL_HOME", "XDG_CONFIG_HOME"])
        var env = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
    static func run(_ path: String, _ args: [String], env: [String: String]? = nil, timeout: Double = 12, input: String? = nil, outputReady: ((String) -> Bool)? = nil) -> EgressProcessOutput {
        let process = Process(), pipe = Pipe(), captured = EgressCapturedBytes(), exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        let inputPipe = input == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = env ?? environment()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return EgressProcessOutput(code: -1, text: error.localizedDescription, timedOut: false, oversized: false) }
        if let input, let inputPipe {
            try? inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        try? pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let next = pipe.fileHandleForReading.availableData
                if next.isEmpty { break }
                captured.append(next, process: process, outputReady: outputReady)
            }
            drained.signal()
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut && process.isRunning {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 1) }
        }
        let complete = drained.wait(timeout: .now() + 3) == .success
        captured.lock.lock(); defer { captured.lock.unlock() }
        return EgressProcessOutput(code: process.isRunning ? -1 : (complete ? process.terminationStatus : -2), text: String(data: captured.data, encoding: .utf8) ?? "", timedOut: timedOut, oversized: captured.oversized)
    }
    static func traceURL(_ host: String) throws -> URL {
        guard hosts.contains(host), let url = URL(string: "https://\(host)/cdn-cgi/trace") else { throw EgressDiagnosticError.message("目标地址不在检测白名单内") }
        return url
    }
    static func parse(_ body: String, host: String, kind: EgressProbeKind, milliseconds: Int, status: Int = 200) -> EgressProbeResult {
        var result = EgressProbeResult(kind: kind, milliseconds: milliseconds)
        guard status == 200 else { result.error = "HTTP \(status)；未取得出口信息"; return result }
        guard body.utf8.count <= 16_384 else { result.error = "响应超过检测大小限制"; return result }
        var fields: [String: String] = [:]
        for line in body.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]).trimmingCharacters(in: .whitespaces) }
        }
        guard fields["h"] == host, let ip = fields["ip"], validIP(ip), let country = fields["loc"], country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else {
            result.error = "响应不是预期的 Cloudflare Trace，无法验证出口"; return result
        }
        result.ip = ip; result.country = country; result.colo = fields["colo"]; result.tls = fields["tls"]
        return result
    }
    static func validIP(_ value: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    static func validateProxyAddress(_ raw: String) throws -> String {
        guard let p = URLComponents(string: raw), ["http", "https", "socks5h", "socks5"].contains(p.scheme ?? ""), let host = p.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }), let port = p.port, (1...65535).contains(port), p.user == nil, p.password == nil, p.query == nil, p.fragment == nil, p.path.isEmpty || p.path == "/" else {
            throw EgressDiagnosticError.message("请填写不含凭证、带端口的 HTTP / HTTPS / SOCKS 代理地址")
        }
        return raw
    }
    static func curlConfigPath(env: [String: String]) -> URL? {
        var paths: [URL] = []
        if let base = env["CURL_HOME"] { paths.append(URL(fileURLWithPath: base).appendingPathComponent(".curlrc")) }
        if let base = env["XDG_CONFIG_HOME"] { paths.append(URL(fileURLWithPath: base).appendingPathComponent("curlrc")) }
        paths.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".curlrc"))
        return paths.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func configSafetyIssue(_ text: String) -> String? {
        let allowed: Set<String> = ["proxy", "noproxy", "ipv4", "ipv6", "http1.1", "http2", "proxy-tunnel", "proxytunnel", "connect-timeout", "max-time", "silent", "show-error"]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let key = String(trimmed.prefix { !$0.isWhitespace && $0 != "=" && $0 != ":" }).replacingOccurrences(of: "--", with: "")
            if !allowed.contains(key) { return "curl 默认配置包含未支持或可能涉及凭证的选项；为避免读取凭证或执行额外请求，本次跳过" }
        }
        return nil
    }
    static func claudeNetworkEnvironment() -> [String: String] {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: path), data.count < 1_000_000, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let env = object["env"] as? [String: Any] else { return [:] }
        return env.reduce(into: [:]) { result, item in if proxyKeys.contains(item.key), let value = item.value as? String { result[item.key] = value } }
    }
    static func maskedProxy(_ raw: String) -> String {
        guard let p = URLComponents(string: raw), let host = p.host else { return "已设置（无法解析）" }
        return "\(p.scheme ?? "http")://\(host)\(p.port.map { ":\($0)" } ?? "")"
    }
    static func curlProbe(kind: EgressProbeKind, host: String, proxy: String) -> EgressProbeResult {
        let started = Date()
        do {
            let url = try traceURL(host)
            var env = environment(), args: [String] = []
            var proxyInput: String?
            func proxyConfiguration(_ address: String) -> String {
                let escaped = address.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
                return "proxy = \"\(escaped)\"\n"
            }
            switch kind {
            case .terminal:
                if let path = curlConfigPath(env: env) {
                    let text = try String(contentsOf: path, encoding: .utf8)
                    if let issue = configSafetyIssue(text) { throw EgressDiagnosticError.message(issue) }
                }
            case .claude:
                args = ["-q"]
                let configured = claudeNetworkEnvironment()
                env.merge(configured) { _, new in new }
                guard let selected = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"].compactMap({ env[$0] }).first(where: { !$0.isEmpty }) else { return EgressProbeResult(kind: kind, skippedReason: "未配置显式代理；已跳过全局配置模拟。TUN 接管不依赖此配置，本项不代表运行中的 Claude 会话。") }
                guard ["http", "https"].contains(URLComponents(string: selected)?.scheme ?? "") else { throw EgressDiagnosticError.message("Claude Code 需要 HTTP / HTTPS 代理；不能用 SOCKS 检测结果替代其实际行为") }
                args += ["--config", "-"]
                proxyInput = proxyConfiguration(selected)
            case .proxy:
                args = ["-q", "--config", "-", "--noproxy", ""]
                proxyInput = proxyConfiguration(try validateProxyAddress(proxy.trimmingCharacters(in: .whitespacesAndNewlines)))
            case .ipv4: args = ["-q", "-4", "--noproxy", "*"]
            case .ipv6: args = ["-q", "-6", "--noproxy", "*"]
            case .browser: throw EgressDiagnosticError.message("浏览器检测需使用纯净浏览器引擎")
            }
            args += ["--silent", "--show-error", "--connect-timeout", "10", "--max-time", "20", "--proto", "=https", "--max-redirs", "0", "--no-insecure", "--request", "GET", "--header", "Cookie:", "--header", "Authorization:", "--write-out", "\nEGRESS_HTTP_STATUS:%{http_code}", url.absoluteString]
            let output = run("/usr/bin/curl", args, env: env, timeout: 22, input: proxyInput)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if output.oversized { throw EgressDiagnosticError.message("响应过大，检测已停止") }
            if output.timedOut || output.code == 28 { return EgressProbeResult(kind: kind, milliseconds: ms, error: "请求超时，未验证出口", timedOut: true) }
            guard output.code == 0 else {
                let messages: [Int32: String] = [-2: "本地进程输出未完整读取，请重试", 5: "无法解析代理地址", 6: "无法解析目标域名", 7: "无法连接目标或代理", 35: "TLS 握手失败", 60: "TLS 证书验证失败", 47: "目标发生重定向，已拒绝继续请求", 56: "连接被关闭"]
                throw EgressDiagnosticError.message(messages[output.code] ?? "请求失败（curl \(output.code)）")
            }
            guard let marker = output.text.range(of: "\nEGRESS_HTTP_STATUS:", options: .backwards), let status = Int(output.text[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) else { throw EgressDiagnosticError.message("无法解析检测状态") }
            return parse(String(output.text[..<marker.lowerBound]), host: host, kind: kind, milliseconds: ms, status: status)
        } catch { return EgressProbeResult(kind: kind, milliseconds: Int(Date().timeIntervalSince(started) * 1000), error: error.localizedDescription) }
    }

}
