import Foundation
import Darwin
import Yams

/// Read-only view of the user's own Clash (Clash Party / Clash Verge / mihomo): finds its controller
/// from the running process and polls /connections. Never calls a mutating endpoint.
@MainActor final class ClashObserver: ObservableObject {
    struct Controller: Equatable { var socket: String?; var address: String?; var secret: String?; var proxyPort: Int? }
    @Published private(set) var controller: Controller?
    @Published private(set) var connections: [LineEngine.Connection] = []
    /// Recently closed watched connections (they vanish from Clash's live list once done).
    @Published private(set) var closed: [LineEngine.Connection] = []
    @Published private(set) var status = "正在查找本机 Clash…"
    /// Exit IP per exit node, learned from exit checks whose probes passed through that node.
    @Published private(set) var exitByNode: [String: (ip: String, at: Date)] = [:]
    /// Domains worth logging: Claude defaults plus every rule domain in the saved lines.
    var watchedDomains: () -> [String] = { ClashObserver.claudeDomains }
    static let claudeDomains = ClaudeRules.recommended.filter { $0.type != "DOMAIN-KEYWORD" }.map(\.value)
    private var task: Task<Void, Never>?
    /// Chain the main Claude hosts currently ride; a change means the user switched node or profile.
    @Published private(set) var claudeRoute: String?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var seen: [String: LineEngine.Connection] = [:]
            while !Task.isCancelled {
                guard let self else { return }
                if self.controller == nil {
                    self.controller = await Task.detached { Self.discover() }.value
                    if self.controller != nil, self.pendingCoverage { Task { await self.checkCoverage() } }
                }
                if let controller = self.controller {
                    let rows = await Task.detached { Self.fetch(controller) }.value
                    if let rows {
                        self.connections = rows
                        self.status = "已连接本机 Clash · \(rows.count) 个连接"
                        seen = self.log(rows, previous: seen)
                        // Keep the last known route while no Claude connection is open.
                        if let route = rows.filter({ EgressLocalDiagnostics.hosts.contains(String($0.host.split(separator: ":").first ?? "")) }).max(by: { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) })?.chain, route != self.claudeRoute { self.claudeRoute = route }
                    } else {
                        self.controller = nil; self.connections = []; self.status = "Clash 控制接口已断开，正在重新查找…"
                    }
                } else { self.status = "未检测到本机 Clash 控制接口" }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Logs watched connections when first seen and when they close.
    private func log(_ rows: [LineEngine.Connection], previous: [String: LineEngine.Connection]) -> [String: LineEngine.Connection] {
        let domains = watchedDomains()
        let watched = rows.filter { Self.matches($0.host, domains) || ClaudeRules.covers($0.host) }
        let ids = Set(watched.map(\.id))
        for row in watched where previous[row.id] == nil {
            TrafficLog.append("CLASH", "open \(row.host) chain=\(row.chain) rule=\(row.rule) exit=\(exitByNode[row.exitNode]?.ip ?? "-")")
        }
        closed = LineEngine.retainClosed(closed, adding: previous.values.filter { !ids.contains($0.id) }.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) })
        for (id, row) in previous where !ids.contains(id) {
            let seconds = row.start.map { Int(Date().timeIntervalSince($0)) } ?? 0
            TrafficLog.append("CLASH", "close \(row.host) exit=\(exitByNode[row.exitNode]?.ip ?? "-") remote=\(row.destination.isEmpty ? "-" : row.destination) chain=\(row.chain) rule=\(row.rule) up=\(row.upload) down=\(row.download) duration=\(seconds)s")
        }
        return Dictionary(uniqueKeysWithValues: watched.map { ($0.id, $0) })
    }

    /// While an exit check runs, watch the live list closely so its short probe connections are seen,
    /// remembering which exit nodes carried watched (Claude) traffic.
    func captureDuringCheck(_ isRunning: @escaping () -> Bool) async -> Set<String> {
        guard let controller else { return [] }
        let started = Date()
        var nodes = Set<String>()
        while isRunning() && Date().timeIntervalSince(started) < 90 {
            let rows = await Task.detached { Self.fetch(controller) }.value ?? []
            for row in rows where EgressLocalDiagnostics.hosts.contains(String(row.host.split(separator: ":").first ?? "")) && (row.start ?? .distantPast) >= started.addingTimeInterval(-1) && !row.exitNode.isEmpty {
                nodes.insert(row.exitNode)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return nodes
    }

    struct RouteCheck: Identifiable, Equatable {
        let id: String, purpose: String
        var node: String? = nil, traceIP: String? = nil, failed = false
    }
    @Published private(set) var coverage: [RouteCheck] = []
    @Published private(set) var checkingCoverage = false
    @Published private(set) var coverageAt: Date?
    /// A check asked for coverage before the controller was found; run it once it is.
    private var pendingCoverage = false

    /// Requests every recommended host through Clash and notes the node that carried it;
    /// Cloudflare hosts also report the exit IP the site saw.
    func checkCoverage() async {
        guard !checkingCoverage, controller != nil else { pendingCoverage = true; return }
        pendingCoverage = false
        checkingCoverage = true; defer { checkingCoverage = false; coverageAt = Date() }
        let controller = self.controller, started = Date(), probes = ClaudeRules.probes
        // Keep the previous rows on screen while probing; the finished run replaces them in one go.
        if coverage.isEmpty { coverage = probes.map { RouteCheck(id: $0.host, purpose: $0.purpose) } }
        let port = controller?.proxyPort
        let requests = Task.detached { Self.runProbes(probes.map { ($0.host, $0.trace) }, proxyPort: port) }
        var nodes: [String: String] = [:]
        if let controller {
            for _ in 0..<80 where nodes.count < probes.count {
                let rows = await Task.detached { Self.fetch(controller) }.value ?? []
                for row in rows where (row.start ?? .distantPast) >= started.addingTimeInterval(-1) {
                    let host = String(row.host.split(separator: ":").first ?? "")
                    if probes.contains(where: { $0.host == host }), nodes[host] == nil, !row.exitNode.isEmpty { nodes[host] = row.exitNode }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        let results = await requests.value
        coverage = probes.map { RouteCheck(id: $0.host, purpose: $0.purpose, node: nodes[$0.host], traceIP: results[$0.host]?.ip, failed: results[$0.host]?.failed ?? true) }
        // A Cloudflare host that went through a node reports that node's real exit: the best evidence available,
        // so it also covers the other hosts on the same node (and fills the gap before the first full exit check maps it).
        for row in coverage { if let node = row.node, let ip = row.traceIP, exitByNode[node]?.ip != ip { exitByNode[node] = (ip, Date()) } }
        let summary = coverage.map { "\($0.id)=\($0.traceIP ?? $0.node.flatMap { exitByNode[$0]?.ip } ?? "?")@\($0.node ?? "-")" }.joined(separator: " ")
        TrafficLog.append("CLASH", "coverage \(summary)")
    }

    nonisolated static func runProbes(_ probes: [(host: String, trace: Bool)], proxyPort: Int?) -> [String: (ip: String?, failed: Bool)] {
        let lock = NSLock()
        var out: [String: (ip: String?, failed: Bool)] = [:]
        DispatchQueue.concurrentPerform(iterations: probes.count) { index in
            let probe = probes[index]
            var args = ["-q", "--silent", "--max-time", "8"]
            if let proxyPort { args += ["--proxy", "http://127.0.0.1:\(proxyPort)"] }
            let result: (ip: String?, failed: Bool)
            if probe.trace {
                let output = EgressLocalDiagnostics.run("/usr/bin/curl", args + ["https://\(probe.host)/cdn-cgi/trace"], timeout: 10)
                result = (EgressLocalDiagnostics.parse(output.text, host: probe.host, kind: .terminal, milliseconds: 0).ip, output.code != 0)
            } else {
                let output = EgressLocalDiagnostics.run("/usr/bin/curl", args + ["-o", "/dev/null", "-I", "https://\(probe.host)/"], timeout: 10)
                result = (nil, output.code != 0)
            }
            lock.withLock { out[probe.host] = result }
        }
        return out
    }

    /// Exit check finished with exactly one exit IP: map it to the nodes its probes used.
    func record(exit ip: String, country: String?, nodes: Set<String>) {
        guard !nodes.isEmpty else { TrafficLog.append("CLASH", "check exit=\(ip) node=unknown"); return }
        for node in nodes {
            let previous = exitByNode[node]?.ip
            exitByNode[node] = (ip, Date())
            if let previous, previous != ip { changedNodes.insert(node); TrafficLog.append("CLASH", "exit changed node=\(node) \(previous) -> \(ip)") }
            else { changedNodes.remove(node); TrafficLog.append("CLASH", "check exit=\(ip) node=\(node) country=\(country ?? "-")") }
        }
    }
    /// Nodes whose exit differed from the previous check (shown in red until the next matching probe).
    @Published private(set) var changedNodes: Set<String> = []

    nonisolated static func matches(_ hostPort: String, _ domains: [String]) -> Bool {
        let host = hostPort.split(separator: ":").first.map(String.init)?.lowercased() ?? hostPort.lowercased()
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Controller from the running core's arguments: `-ext-ctl-unix <sock>` / `-ext-ctl <addr>`,
    /// else `external-controller` + `secret` from the config in its `-d` directory.
    nonisolated static func discover() -> Controller? {
        let ps = EgressLocalDiagnostics.run("/bin/ps", ["-axo", "pid=,ucomm="], timeout: 5)
        for line in ps.text.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int32(parts[0]), parts[1].lowercased().contains("mihomo") || parts[1].lowercased().contains("clash"),
                  let args = arguments(pid) ?? psArguments(pid), let exe = args.first,
                  !exe.hasPrefix(Bundle.main.bundlePath), !args.contains(where: { $0.hasPrefix("/tmp/cc-") })  // not our own engine
            else { continue }
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            var controller = Controller(socket: value("-ext-ctl-unix"), address: value("-ext-ctl"), secret: value("-secret"))
            if let dir = value("-d"), let config = try? String(contentsOfFile: value("-f") ?? dir + "/config.yaml", encoding: .utf8),
               let yaml = try? Yams.load(yaml: config) as? [String: Any] {
                if controller.socket == nil, controller.address == nil {
                    controller.socket = (yaml["external-controller-unix"] as? String).flatMap { $0.isEmpty ? nil : ($0.hasPrefix("/") ? $0 : dir + "/" + $0) }
                    controller.address = (yaml["external-controller"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    controller.secret = controller.secret ?? (yaml["secret"] as? String)
                }
                // Probe through Clash's own port so it works without TUN too.
                controller.proxyPort = [yaml["mixed-port"], yaml["port"]].compactMap { $0 as? Int }.first { $0 > 0 }
            }
            if controller.socket != nil || controller.address != nil, fetch(controller) != nil { return controller }
        }
        return nil
    }

    /// Exact argv via KERN_PROCARGS2 (paths may contain spaces, so `ps` output can't be split).
    nonisolated static func arguments(_ pid: Int32) -> [String]? {
        var keys: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&keys, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&keys, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let count = Int(bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var cursor = 4
        func next() -> String? {
            guard cursor < size, let end = bytes[cursor..<size].firstIndex(of: 0) else { return nil }
            defer { cursor = end + 1 }
            return String(decoding: bytes[cursor..<end], as: UTF8.self)
        }
        _ = next()  // executable path
        while cursor < size && bytes[cursor] == 0 { cursor += 1 }
        var args: [String] = []
        for _ in 0..<max(0, min(count, 256)) { guard let arg = next() else { break }; args.append(arg) }
        return args.isEmpty ? nil : args
    }

    /// Fallback for cores running as root (Clash Party's helper), whose argv sysctl can't read:
    /// `ps` can, but prints one string, so split before each flag rather than at every space.
    nonisolated static func psArguments(_ pid: Int32) -> [String]? {
        let text = EgressLocalDiagnostics.run("/bin/ps", ["-o", "args=", "-p", String(pid)], timeout: 5).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return splitFlags(text)
    }
    nonisolated static func splitFlags(_ text: String) -> [String] {
        var args: [String] = []
        for (index, chunk) in text.components(separatedBy: " -").enumerated() {
            if index == 0 { args.append(chunk); continue }
            let pair = chunk.split(separator: " ", maxSplits: 1).map(String.init)
            args.append("-" + pair[0])
            if pair.count == 2 { args.append(pair[1]) }
        }
        return args
    }

    nonisolated static func fetch(_ controller: Controller) -> [LineEngine.Connection]? {
        var args = ["-q", "--silent", "--fail", "--max-time", "3", "--noproxy", "*", "--config", "-"]
        let url: String
        if let socket = controller.socket { args += ["--unix-socket", socket]; url = "http://localhost/connections" }
        else if let address = controller.address {
            let host = address.hasPrefix(":") ? "127.0.0.1" + address : address.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
            url = "http://\(host)/connections"
        } else { return nil }
        let output = EgressLocalDiagnostics.run("/usr/bin/curl", args + [url], timeout: 4, input: controller.secret.map { "header = \"Authorization: Bearer \($0)\"\n" } ?? "")
        guard output.code == 0, !output.oversized, let data = output.text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["connections"] != nil || root["downloadTotal"] != nil else { return nil }
        return LineEngine.parseConnections(root)
    }
}
