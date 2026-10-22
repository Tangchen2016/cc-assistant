import Foundation
import Yams

enum SubscriptionDelay {
    private static let registryLock = NSLock()
    private static var active: [Int32: Process] = [:]
    static func stopAll() {
        let processes = registryLock.withLock { Array(active.values) }
        for process in processes { stop(process) }
    }

    static var engine: URL? {
        #if arch(arm64)
        Bundle.main.url(forResource: "mihomo-arm64", withExtension: nil)
        #else
        Bundle.main.url(forResource: "mihomo-x64", withExtension: nil)
        #endif
    }
    static func controller(socket: String, secret: String, _ path: String, timeout: Double) throws -> [String: Any] {
        let result = EgressLocalDiagnostics.run("/usr/bin/curl", ["-q", "--silent", "--fail", "--max-time", String(timeout), "--noproxy", "*", "--unix-socket", socket, "--config", "-", "http://localhost" + path], timeout: timeout + 1, input: "header = \"Authorization: Bearer \(secret)\"\n")
        guard result.code == 0, let data = result.text.data(using: .utf8), data.count < 65536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SubscriptionFailure("节点连接失败") }; return object
    }
    /// Fire-and-check controller call (PUT/DELETE answer 204 with no body).
    @discardableResult static func controllerSend(socket: String, secret: String, method: String, _ path: String, body: String? = nil) -> Bool {
        var args = ["-q", "--silent", "--fail", "--max-time", "3", "--noproxy", "*", "--unix-socket", socket, "--config", "-", "-X", method]
        if let body { args += ["-H", "Content-Type: application/json", "--data-binary", body] }
        return EgressLocalDiagnostics.run("/usr/bin/curl", args + ["http://localhost" + path], timeout: 4, input: "header = \"Authorization: Bearer \(secret)\"\n").code == 0
    }
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<10 { if !process.isRunning { return }; Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    static func measure(source: SubscriptionSource, name: String, entry: String?) async -> String {
        let directory = URL(fileURLWithPath: "/tmp/cc-delay-\(UUID().uuidString)")
        let process = Process()
        var registeredPID: Int32?
        do {
            let nodesByName = Dictionary(uniqueKeysWithValues: source.nodes.compactMap { n in (n["name"] as? String).map { ($0, n) } })
            var selected: [[String: Any]] = [], visited = Set<String>()
            let allowed = Set("name type server port udp tfo mptcp ip-version dialer-proxy tls sni servername skip-cert-verify alpn client-fingerprint fingerprint name-cert-verify network ws-opts grpc-opts h2-opts http-opts reality-opts cipher password plugin plugin-opts udp-over-tcp udp-over-tcp-version uuid alterId packet-encoding global-padding authenticated-length flow username headers auth auth-str up down ports protocol obfs disable-mtu-discovery recv-window-conn recv-window obfs-password hop-interval token heartbeat-interval disable-sni reduce-rtt request-timeout udp-relay-mode congestion-controller max-udp-relay-packet-size fast-open max-open-streams psk version obfs-opts idle-session-check-interval idle-session-timeout min-idle-session".split(separator: " ").map(String.init))
            func collect(_ key: String) throws {
                guard visited.insert(key).inserted, var node = nodesByName[key] else { throw SubscriptionFailure("节点缺失或存在循环") }
                guard Set(node.keys).isSubset(of: allowed), let host = node["server"] as? String, let type = node["type"] as? String, ["ss", "vmess", "vless", "trojan", "http", "socks5", "hysteria", "hysteria2", "tuic", "snell", "anytls"].contains(type) else { throw SubscriptionFailure("不支持该节点配置") }
                _ = try SubscriptionCore.publicURL("https://\(host)")
                if let options = node["plugin-opts"] as? [String: Any], options.keys.contains(where: { !["mode", "host", "path", "tls", "skip-cert-verify", "headers", "mux", "version", "password", "fingerprint", "obfs", "obfs-host", "obfs-uri"].contains($0) }) { throw SubscriptionFailure("不支持的插件配置") }
                if key == name, let entry { guard node["dialer-proxy"] == nil else { throw SubscriptionFailure("出口已有前置代理") }; node["dialer-proxy"] = entry }
                if let upstream = node["dialer-proxy"] as? String { try collect(upstream) }
                selected.append(node)
            }
            try collect(name)
            for node in selected { if let host = node["server"] as? String { try await SubscriptionNetwork.checkHost(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) } }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer {
                stop(process)
                if let registeredPID { _ = registryLock.withLock { active.removeValue(forKey: registeredPID) } }
                try? FileManager.default.removeItem(at: directory)
            }
            let socket = directory.appendingPathComponent("api.sock").path, secret = try SubscriptionCore.token(32)
            let config: [String: Any] = ["port": 0, "mixed-port": 0, "socks-port": 0, "allow-lan": false, "bind-address": "127.0.0.1", "mode": "rule", "log-level": "silent", "ipv6": true, "external-controller": "", "external-controller-unix": socket, "secret": secret, "geo-auto-update": false, "find-process-mode": "off", "dns": ["enable": false], "tun": ["enable": false], "proxies": selected, "proxy-groups": [], "rules": ["MATCH,REJECT"]]
            let file = directory.appendingPathComponent("config.yaml")
            try SubscriptionStorage.privateWrite(Data(try Yams.dump(object: config).utf8), to: file)
            guard let binary = engine else { return "测速引擎缺失" }
            process.executableURL = binary; process.arguments = ["-d", directory.path, "-f", file.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            registeredPID = process.processIdentifier
            registryLock.withLock { active[process.processIdentifier] = process }
            func api(_ path: String, timeout: Double) throws -> [String: Any] { try controller(socket: socket, secret: secret, path, timeout: timeout) }
            var ready = false
            for _ in 0..<30 { if !process.isRunning { break }; if (try? api("/version", timeout: 0.2)) != nil { ready = true; break }; try await Task.sleep(nanoseconds: 100_000_000) }
            guard ready else { return "内核启动失败" }
            let target = "https://www.gstatic.com/generate_204"
            let result = try api("/proxies/\(SubscriptionCore.encoded(name))/delay?url=\(SubscriptionCore.encoded(target))&timeout=5000&expected=204", timeout: 7)
            guard let delay = result["delay"] as? Int, delay > 0 else { return "不可用" }
            let state = try api("/proxies/\(SubscriptionCore.encoded(name))", timeout: 2)
            guard let extra = state["extra"] as? [String: Any], let tested = extra[target] as? [String: Any], tested["alive"] as? Bool == true else { return "响应异常" }
            return "\(delay) ms"
        } catch { return "不可用" }
    }
}
