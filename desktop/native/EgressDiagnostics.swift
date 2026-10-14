import Foundation
import CryptoKit
import Darwin
import WebKit

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
        case .browser: return "独立浏览器 · 无登录态"
        }
    }
    var detail: String {
        switch self {
        case .terminal: return "读取 curl 默认配置，继承 App 启动环境"
        case .claude: return "按 Claude 全局代理配置请求，不调用模型"
        case .proxy: return "仅在自定义代理开关开启时，使用指定地址请求"
        case .ipv4: return "忽略显式代理；仍可能由 TUN 接管"
        case .ipv6: return "忽略显式代理；用于发现 IPv6 旁路"
        case .browser: return "临时 WebKit 会话；不是已有 Chrome / Safari 会话"
        }
    }
    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .claude: return "gearshape"
        case .proxy: return "arrow.triangle.branch"
        case .ipv4: return "4.circle"
        case .ipv6: return "6.circle"
        case .browser: return "safari"
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
    var finishedAt = Date()
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
    func append(_ next: Data, process: Process) {
        lock.lock()
        if data.count + next.count > 4_000_000 { oversized = true } else { data.append(next) }
        let stop = oversized
        lock.unlock()
        if stop && process.isRunning { process.terminate() }
    }
}

enum EgressLocalDiagnostics {
    static let hosts = ["api.anthropic.com", "claude.ai", "platform.claude.com"]
    static let proxyKeys = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY"]
    static func environment() -> [String: String] {
        let allowed = Set(proxyKeys + ["HOME", "PATH", "LANG", "LC_ALL", "CURL_HOME", "XDG_CONFIG_HOME"])
        var env = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
    static func run(_ path: String, _ args: [String], env: [String: String]? = nil, timeout: Double = 12, input: String? = nil) -> EgressProcessOutput {
        let process = Process(), pipe = Pipe(), captured = EgressCapturedBytes(), exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        let inputPipe = input == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = env ?? environment()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return EgressProcessOutput(code: -1, text: "", timedOut: false, oversized: false) }
        if let input, let inputPipe {
            try? inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        try? pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let next = pipe.fileHandleForReading.availableData
                if next.isEmpty { break }
                captured.append(next, process: process)
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
                guard let selected = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"].compactMap({ env[$0] }).first(where: { !$0.isEmpty }) else { throw EgressDiagnosticError.message("Claude 全局配置和 App 启动环境中没有显式代理；本项仅模拟全局配置，不代表运行中的会话") }
                guard ["http", "https"].contains(URLComponents(string: selected)?.scheme ?? "") else { throw EgressDiagnosticError.message("Claude Code 需要 HTTP / HTTPS 代理；不能用 SOCKS 检测结果替代其实际行为") }
                args += ["--config", "-"]
                proxyInput = proxyConfiguration(selected)
            case .proxy:
                args = ["-q", "--config", "-", "--noproxy", ""]
                proxyInput = proxyConfiguration(try validateProxyAddress(proxy.trimmingCharacters(in: .whitespacesAndNewlines)))
            case .ipv4: args = ["-q", "-4", "--noproxy", "*"]
            case .ipv6: args = ["-q", "-6", "--noproxy", "*"]
            case .browser: throw EgressDiagnosticError.message("浏览器检测需使用独立 WebKit 会话")
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

@MainActor final class EgressBrowserProbe: NSObject, WKNavigationDelegate {
    private var view: WKWebView?
    private var continuation: CheckedContinuation<EgressProbeResult, Never>?
    private var timer: Task<Void, Never>?
    private var started = Date()
    private var target: URL?
    private var startCookies = 0
    private var status = 0
    private var navigationIssued = false
    nonisolated static func permits(_ url: URL, target: URL) -> Bool {
        url.scheme == target.scheme && url.host == target.host && url.port == target.port && url.path == "/cdn-cgi/trace" && url.query == nil && url.fragment == nil && url.user == nil && url.password == nil
    }
    func check(host: String, fixture: URL? = nil) async -> EgressProbeResult {
        navigationIssued = false
        status = 0
        startCookies = 0
        do { target = try fixture ?? EgressLocalDiagnostics.traceURL(host) } catch { return EgressProbeResult(kind: .browser, error: error.localizedDescription) }
        guard let target else { return EgressProbeResult(kind: .browser, error: "没有检测目标") }
        let store = WKWebsiteDataStore.nonPersistent()
        guard !store.isPersistent else { return EgressProbeResult(kind: .browser, error: "无法创建临时浏览器，检测已拒绝") }
        let cookies = await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
        startCookies = cookies.count
        guard cookies.isEmpty else { return EgressProbeResult(kind: .browser, error: "临时会话含 Cookie，检测已拒绝", cookiesAtStart: cookies.count) }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        view = WKWebView(frame: .zero, configuration: config)
        view?.navigationDelegate = self
        started = Date()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 22_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(EgressProbeResult(kind: .browser, error: "独立浏览器连接超时，未验证出口", timedOut: true))
            }
            var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("", forHTTPHeaderField: "Cookie")
            request.setValue("", forHTTPHeaderField: "Authorization")
            view?.load(request)
        }
    }
    private func finish(_ result: EgressProbeResult) {
        guard let continuation else { return }
        self.continuation = nil
        var result = result
        result.cookiesAtStart = startCookies
        result.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        timer?.cancel(); timer = nil
        view?.stopLoading(); view?.navigationDelegate = nil; view = nil
        continuation.resume(returning: result)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === view else { decisionHandler(.cancel); return }
        guard !navigationIssued, let url = navigationAction.request.url, let target, Self.permits(url, target: target) else {
            decisionHandler(.cancel); finish(EgressProbeResult(kind: .browser, error: "检测遇到重定向或非白名单地址，已停止")); return
        }
        navigationIssued = true
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard webView === view else { return }
        finish(EgressProbeResult(kind: .browser, error: "检测遇到服务器重定向，已停止"))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard webView === view else { decisionHandler(.cancel); return }
        guard let response = navigationResponse.response as? HTTPURLResponse, let url = response.url, let target, Self.permits(url, target: target), response.expectedContentLength <= 16_384 else {
            decisionHandler(.cancel); finish(EgressProbeResult(kind: .browser, error: "浏览器响应不符合检测限制")); return
        }
        status = response.statusCode
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard webView === view else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil); finish(EgressProbeResult(kind: .browser, error: "目标要求身份认证，已拒绝发送凭证")) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === view else { return }
        webView.evaluateJavaScript("document.body.innerText") { [weak self] value, error in
            guard let self, let target = self.target else { return }
            if error != nil || !(value is String) { self.finish(EgressProbeResult(kind: .browser, error: "无法读取独立浏览器检测响应")); return }
            self.finish(EgressLocalDiagnostics.parse(value as! String, host: target.host ?? "", kind: .browser, milliseconds: 0, status: self.status))
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { guard webView === view else { return }; finish(EgressProbeResult(kind: .browser, error: "浏览器连接失败（\((error as NSError).code)）", timedOut: (error as NSError).code == NSURLErrorTimedOut)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { guard webView === view else { return }; finish(EgressProbeResult(kind: .browser, error: "浏览器连接失败（\((error as NSError).code)）；请检查系统代理", timedOut: (error as NSError).code == NSURLErrorTimedOut)) }
}
