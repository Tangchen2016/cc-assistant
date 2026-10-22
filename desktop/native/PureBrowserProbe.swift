import Foundation

struct PureBrowserConfiguration: Sendable {
    let executable: URL
    let name: String
    let proxy: String
    var timeZone: String? = nil

    func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = base
        result.removeValue(forKey: "TZ")
        if let timeZone { result["TZ"] = timeZone }
        return result
    }

    func arguments(profile: URL) -> [String] {
        ["--user-data-dir=\(profile.path)", "--profile-directory=Default", "--proxy-server=\(proxy)", "--no-first-run", "--no-default-browser-check", "--disable-sync", "--disable-extensions", "--disable-quic", "--force-webrtc-ip-handling-policy=disable_non_proxied_udp"]
    }
}

enum PureBrowserProbe {
    static func traceText(_ html: String) -> String? {
        guard html.utf8.count <= 262144,
              let expression = try? NSRegularExpression(pattern: "<pre\\b[^>]*>([\\s\\S]*?)</pre>", options: [.caseInsensitive]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range]).replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func check(host: String, configuration: PureBrowserConfiguration) -> EgressProbeResult {
        let started = Date()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cc-egress-browser-\(UUID().uuidString)", isDirectory: true)
        do {
            let target = try EgressLocalDiagnostics.traceURL(host)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let arguments = configuration.arguments(profile: directory) + ["--headless=new", "--dump-dom", "--timeout=15000", "--disable-background-networking", target.absoluteString]
            let output = EgressLocalDiagnostics.run(configuration.executable.path, arguments, env: configuration.environment(), timeout: 22, outputReady: { html in
                guard let text = traceText(html) else { return false }
                return EgressLocalDiagnostics.parse(text, host: host, kind: .browser, milliseconds: 0).isSuccess
            })
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            guard !output.oversized, let text = traceText(output.text) else {
                if output.timedOut { return EgressProbeResult(kind: .browser, milliseconds: elapsed, error: "纯净浏览器连接超时", timedOut: true) }
                return EgressProbeResult(kind: .browser, milliseconds: elapsed, error: "纯净浏览器未返回有效检测页面；请检查浏览器及其代理设置")
            }
            var result = EgressLocalDiagnostics.parse(text, host: host, kind: .browser, milliseconds: elapsed)
            result.browserName = configuration.name
            return result
        } catch { return EgressProbeResult(kind: .browser, error: "无法创建纯净浏览器检测环境") }
    }
}
