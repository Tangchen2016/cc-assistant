import Foundation

/// Local audit trail for traffic the built-in proxy carries: one file per day, kept 14 days.
/// Records domains, IPs, chains, byte counts and gate decisions — never request contents.
enum TrafficLog {
    static let retentionDays = 14
    private static let lock = NSLock()
    static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("cc助手/logs", isDirectory: true) }

    /// `kind`: REQ (each request, incl. blocked), CONN (closed connection summary), GATE, ENGINE.
    static func append(_ kind: String, _ message: String, at date: Date = Date()) {
        let line = "\(stamp(date)) \(kind) \(message.replacingOccurrences(of: "\n", with: " "))\n"
        lock.withLock {
            let file = directory.appendingPathComponent("traffic-\(day(date)).log")
            if !FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    static func prune(now: Date = Date()) {
        let cutoff = day(now.addingTimeInterval(-Double(retentionDays) * 86_400))
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let name = file.lastPathComponent
            guard name.hasPrefix("traffic-"), name.hasSuffix(".log") else { continue }
            if String(name.dropFirst(8).dropLast(4)) < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// mihomo writes `time="…" level=info msg="[TCP] a --> b match R using G[P]"`; keep the msg.
    static func message(fromEngineLine line: String) -> String? {
        guard let start = line.range(of: "msg=\"") else { return line.isEmpty ? nil : line }
        var text = String(line[start.upperBound...])
        if text.hasSuffix("\"") { text.removeLast() }
        return text.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func day(_ date: Date) -> String { format(date, "yyyy-MM-dd") }
    private static func stamp(_ date: Date) -> String { format(date, "yyyy-MM-dd HH:mm:ss.SSS") }
    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
