import Foundation
import Darwin
import Yams

/// Built-in line: the bundled mihomo serves one saved route on a loopback port,
/// so managed browsers and terminals work without Clash on the user's machine.
enum LineEngine {
    // ponytail: built-in proxy shelved for now — the Clash subscription carries the dedicated group. Flip to bring the UI back.
    static let enabled = false
    // ponytail: one fixed port, one active line; per-line ports if users need several lines at once.
    static let port = 17890
    static let address = "http://127.0.0.1:\(port)"
    /// Probe-only listener pinned to the line; it bypasses the gate so a blocked line can still be re-verified.
    static let probePort = 17891
    /// Select group every request passes; REJECT first = closed until the exit is verified (fail-closed).
    static let gate = "cc-gate"
    private static let lock = NSLock()
    private static var running: (process: Process, key: String, directory: URL, socket: String, secret: String, group: String)?
    private static var pidFile: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("cc助手/line-engine.pid") }

    /// Keep only what `group` reaches and send every TCP request through it.
    static func config(yaml: String, group: String, socket: String, secret: String) throws -> [String: Any] {
        guard let source = try Yams.load(yaml: yaml) as? [String: Any] else { throw SubscriptionFailure("线路配置无效") }
        let proxies = Dictionary((source["proxies"] as? [[String: Any]] ?? []).compactMap { p in (p["name"] as? String).map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        let groups = Dictionary((source["proxy-groups"] as? [[String: Any]] ?? []).compactMap { g in (g["name"] as? String).map { ($0, g) } }, uniquingKeysWith: { a, _ in a })
        guard groups[group] != nil else { throw SubscriptionFailure("线路缺少代理组「\(group)」") }
        guard proxies[gate] == nil, groups[gate] == nil else { throw SubscriptionFailure("线路中已有名为 \(gate) 的节点或代理组") }
        var keptProxies: [[String: Any]] = [], keptGroups: [[String: Any]] = [], visited = Set<String>()
        func walk(_ name: String) throws {
            guard !SubscriptionCore.reserved.contains(name.uppercased()), visited.insert(name).inserted else { return }
            if let proxy = proxies[name] {
                keptProxies.append(proxy)
                if let upstream = proxy["dialer-proxy"] as? String { try walk(upstream) }
            } else if let g = groups[name] {
                guard g["use"] == nil, g["include-all"] as? Bool != true, g["include-all-proxies"] as? Bool != true, let children = g["proxies"] as? [String] else { throw SubscriptionFailure("代理组「\(name)」使用了动态节点，内置代理暂不支持") }
                keptGroups.append(g)
                for child in children { try walk(child) }
            } else { throw SubscriptionFailure("线路引用的节点「\(name)」不存在") }
        }
        try walk(group)
        return ["port": 0, "socks-port": 0, "mixed-port": port, "allow-lan": false, "bind-address": "127.0.0.1", "mode": "rule", "log-level": "info", "ipv6": true,
                "external-controller": "", "external-controller-unix": socket, "secret": secret, "geo-auto-update": false, "find-process-mode": "off",
                "profile": ["store-selected": false], "dns": ["enable": false], "tun": ["enable": false],
                "proxies": keptProxies, "proxy-groups": keptGroups + [["name": gate, "type": "select", "proxies": ["REJECT", group]]],
                "listeners": [["name": "cc-probe", "type": "mixed", "port": probePort, "listen": "127.0.0.1", "proxy": group]],
                "rules": ["NETWORK,UDP,REJECT", "MATCH,\(gate)"]]
    }

    static func isRunning(key: String) -> Bool { lock.withLock { running?.key == key && running?.process.isRunning == true } }

    /// `key` identifies the saved line version; an identical running line is left alone.
    static func start(yaml: String, group: String, key: String) async throws {
        if isRunning(key: key) { return }
        stop()
        guard let binary = SubscriptionDelay.engine else { throw SubscriptionFailure("线路引擎缺失，请重新安装 App") }
        killStale(binary)
        guard portFree() else { throw SubscriptionFailure("本机端口 \(port) 已被占用，内置代理无法启动") }
        // Short /tmp path: unix socket paths are limited to 104 bytes.
        let directory = URL(fileURLWithPath: "/tmp/cc-line-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let socket = directory.appendingPathComponent("api.sock").path, secret = try SubscriptionCore.token(32)
        let file = directory.appendingPathComponent("config.yaml")
        let process = Process()
        do {
            try SubscriptionStorage.privateWrite(Data(try Yams.dump(object: config(yaml: yaml, group: group, socket: socket, secret: secret)).utf8), to: file)
            process.executableURL = binary; process.arguments = ["-d", directory.path, "-f", file.path]
            process.standardInput = FileHandle.nullDevice
            // Every request mihomo handles (including gate rejects) goes to the traffic log.
            let pipe = Pipe(), splitter = LineSplitter { line in
                guard let message = TrafficLog.message(fromEngineLine: line) else { return }
                TrafficLog.append(message.contains("-->") ? "REQ" : "ENGINE", message)
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { splitter.feed(data) }
            }
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            TrafficLog.prune()
            TrafficLog.append("ENGINE", "start key=\(key) group=\(group) listen=\(address)")
            lock.withLock { running = (process, key, directory, socket, secret, group) }
            try? FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? SubscriptionStorage.privateWrite(Data(String(process.processIdentifier).utf8), to: pidFile)
            for _ in 0..<30 {
                guard process.isRunning else { break }
                if (try? SubscriptionDelay.controller(socket: socket, secret: secret, "/version", timeout: 0.2)) != nil, !portFree() { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw SubscriptionFailure("内置代理启动失败")
        } catch { stop(); try? FileManager.default.removeItem(at: directory); throw error }
    }

    static func stop() {
        guard let current = lock.withLock({ () -> (process: Process, key: String, directory: URL, socket: String, secret: String, group: String)? in defer { running = nil }; return running }) else { return }
        SubscriptionDelay.stop(current.process)
        TrafficLog.append("ENGINE", "stop key=\(current.key)")
        try? FileManager.default.removeItem(at: current.directory)
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Open lets requests through the line; closing also drops live connections so nothing keeps flowing.
    @discardableResult static func setGate(open: Bool) -> Bool {
        guard let current = lock.withLock({ running }) else { return false }
        let body = String(data: (try? JSONSerialization.data(withJSONObject: ["name": open ? current.group : "REJECT"])) ?? Data(), encoding: .utf8)
        let switched = SubscriptionDelay.controllerSend(socket: current.socket, secret: current.secret, method: "PUT", "/proxies/\(gate)", body: body)
        if !open { SubscriptionDelay.controllerSend(socket: current.socket, secret: current.secret, method: "DELETE", "/connections") }
        return switched
    }

    /// The exit Claude actually sees through this line (Cloudflare trace on api.anthropic.com).
    static func probeExit() -> EgressProbeResult {
        let host = "api.anthropic.com"
        let started = Date()
        let output = EgressLocalDiagnostics.run("/usr/bin/curl", ["-q", "--silent", "--max-time", "10", "--proxy", "http://127.0.0.1:\(probePort)", "https://\(host)/cdn-cgi/trace"], timeout: 12)
        guard output.code == 0 else { return EgressProbeResult(kind: .proxy, error: "经内置代理访问出口检测失败") }
        return EgressLocalDiagnostics.parse(output.text, host: host, kind: .proxy, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    struct Connection: Identifiable, Equatable {
        let id: String, host: String, destination: String, chain: String, rule: String, upload: Int, download: Int, start: Date?
        /// The node that actually leaves the core (mihomo lists it first in `chains`).
        var exitNode: String = ""
        /// Set once the connection has gone from the core's live list.
        var closedAt: Date? = nil
    }
    /// Live connections through the engine (mihomo /connections); empty when not running.
    static func connections() -> [Connection] {
        guard let current = lock.withLock({ running }) else { return [] }
        let output = EgressLocalDiagnostics.run("/usr/bin/curl", ["-q", "--silent", "--fail", "--max-time", "3", "--noproxy", "*", "--unix-socket", current.socket, "--config", "-", "http://localhost/connections"], timeout: 4, input: "header = \"Authorization: Bearer \(current.secret)\"\n")
        guard output.code == 0, !output.oversized, let data = output.text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return parseConnections(root)
    }
    /// Keeps recently closed connections for tracing: last 30 minutes, at most 500.
    static func retainClosed(_ history: [Connection], adding closed: [Connection], now: Date = Date()) -> [Connection] {
        let stamped = closed.map { row -> Connection in var row = row; row.closedAt = now; return row }
        return Array((stamped + history).filter { now.timeIntervalSince($0.closedAt ?? now) <= 1800 }.prefix(500))
    }

    static func parseConnections(_ root: [String: Any]) -> [Connection] {
        let iso = ISO8601DateFormatter()
        return (root["connections"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let meta = item["metadata"] as? [String: Any] else { return nil }
            let host = (meta["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (meta["destinationIP"] as? String ?? "?")
            let port = meta["destinationPort"] as? String ?? (meta["destinationPort"] as? Int).map(String.init) ?? ""
            // mihomo lists chains exit-first; show them in travel order.
            let chain = (item["chains"] as? [String] ?? []).reversed().filter { $0 != gate }.joined(separator: " → ")
            let remote = (meta["remoteDestination"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (meta["destinationIP"] as? String ?? "")
            return Connection(id: id, host: port.isEmpty ? host : "\(host):\(port)", destination: remote,
                              chain: chain, rule: item["rule"] as? String ?? "", upload: item["upload"] as? Int ?? 0, download: item["download"] as? Int ?? 0,
                              // mihomo stamps microseconds ("…05.572852+08:00"); drop the fraction for ISO8601DateFormatter.
                              start: (item["start"] as? String).flatMap { iso.date(from: $0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)) },
                              exitNode: (item["chains"] as? [String])?.first ?? "")
        }.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
    }

    /// Only an exit identical to the marked IP is allowed through.
    static func gateDecision(exit: String?, marked: String?) -> (open: Bool, reason: String) {
        guard let marked else { return (false, "尚未标记出口 IP，已拦截") }
        guard let exit, let ip = EgressIPHistory.normalized(exit) else { return (false, "无法确认出口，已拦截") }
        return ip == EgressIPHistory.normalized(marked) ? (true, "出口 \(ip) 与标记一致") : (false, "出口 \(ip) 与标记 \(marked) 不一致，已拦截")
    }

    /// A crashed app can leave its engine holding the port; only kill it if it is our bundled binary.
    private static func killStale(_ binary: URL) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text), pid > 1 else { return }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == binary.path { kill(pid, SIGTERM); usleep(300_000) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    private static func portFree() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1 // TIME_WAIT from a just-stopped engine is not "occupied"
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}

/// Reassembles pipe chunks into whole lines.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void
    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }
    func feed(_ data: Data) {
        let lines: [String] = lock.withLock {
            buffer.append(data)
            var out: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                out.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > 65_536 { buffer.removeAll() }  // a runaway line is dropped, not buffered forever
            return out
        }
        lines.forEach(onLine)
    }
}
