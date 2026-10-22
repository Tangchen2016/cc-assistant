import Foundation
import Darwin

struct BrowserProcessIdentity {
    let pid: pid_t
    let executable: String
    let arguments: [String]
    let timeZone: String?
    var sessionID: String? { arguments.first { $0.hasPrefix("--cc-assistant-session-id=") }.map { String($0.dropFirst("--cc-assistant-session-id=".count)) } }
    var proxy: String? { arguments.first { $0.hasPrefix("--proxy-server=") }.map { String($0.dropFirst("--proxy-server=".count)) } }

    // Read only the owner process referenced by this private profile's lock.
    static func read(profile: URL, allowedExecutables: [URL]) -> BrowserProcessIdentity? {
        guard let lock = try? FileManager.default.destinationOfSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path),
              let part = lock.split(separator: "-").last, let pid = Int32(part), pid > 1, kill(pid, 0) == 0 else { return nil }
        var keys: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&keys, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&keys, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return parse(Array(bytes.prefix(size)), pid: pid, profile: profile, allowedExecutables: allowedExecutables)
    }
    static func parse(_ bytes: [UInt8], pid: pid_t, profile: URL, allowedExecutables: [URL]) -> BrowserProcessIdentity? {
        guard bytes.count > 4 else { return nil }
        let count = bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 512 else { return nil }
        var cursor = 4
        func string() -> String? {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0),
                  let result = String(bytes: bytes[cursor..<end], encoding: .utf8) else { return nil }
            cursor = end + 1; return result
        }
        guard let executable = string(), allowedExecutables.contains(where: { $0.standardizedFileURL.path == URL(fileURLWithPath: executable).standardizedFileURL.path }) else { return nil }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<count { guard let value = string() else { return nil }; arguments.append(value) }
        guard arguments.contains("--user-data-dir=\(profile.path)") else { return nil }
        var timeZone: String?
        while cursor < bytes.count {
            guard let value = string(), !value.isEmpty else { break }
            if value.hasPrefix("TZ=") { timeZone = String(value.dropFirst(3)) }
        }
        return .init(pid: pid, executable: executable, arguments: arguments, timeZone: timeZone)
    }
}

enum BrowserRunPhase: String {
    case stopped = "未运行", starting = "启动中", running = "运行中", unverified = "运行中 · 设置未确认", restartRequired = "运行中 · 待重启", stopping = "关闭中", failed = "启动失败"
}
struct BrowserRuntimeState {
    var phase: BrowserRunPhase = .stopped
    var pid: pid_t?
    var usesCustomIcon = false
}

struct BrowserLaunchRecord: Codable {
    let pid: pid_t
    let sessionID: String
    let proxy: String
    let timeZone: String?
    static func file(profile: URL) -> URL { profile.appendingPathComponent(".cc-assistant-launch.json") }
    static func read(profile: URL, identity: BrowserProcessIdentity) -> BrowserLaunchRecord? {
        guard let token = identity.sessionID, let data = try? Data(contentsOf: file(profile: profile)), data.count <= 4096,
              let record = try? JSONDecoder().decode(Self.self, from: data), record.pid == identity.pid, record.sessionID == token else { return nil }
        return record
    }
}
