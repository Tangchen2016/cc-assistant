import AppKit
import Foundation

// Owns only Chrome processes started for cc助手's private profiles.
@MainActor final class ManagedChrome {
    private struct Session {
        let process: Process; let proxy: String; let timeZone: String?
        let started = Date(); var closing = false
    }
    private var sessions: [String: Session] = [:]
    private var closingPIDs = Set<pid_t>()
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "\(home)/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium"]
            .map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    private func observed(profile: URL, source: URL) -> BrowserProcessIdentity? {
        BrowserProcessIdentity.read(profile: profile, allowedExecutables: [source, ChromeBrowserIdentity.executable(profile: profile, source: source)])
    }
    func runtime(profile: URL, configuration: PureBrowserConfiguration) -> BrowserRuntimeState {
        if let session = sessions[profile.path] {
            if session.process.isRunning {
                let changed = session.proxy != configuration.proxy || session.timeZone != configuration.timeZone
                let phase: BrowserRunPhase = session.closing ? .stopping : changed ? .restartRequired : Date().timeIntervalSince(session.started) < 1 ? .starting : .running
                return .init(phase: phase, pid: session.process.processIdentifier, usesCustomIcon: session.process.executableURL != configuration.executable)
            }
            sessions.removeValue(forKey: profile.path)
            if !session.closing && session.process.terminationStatus != 0 { return .init(phase: .failed) }
        }
        guard let identity = observed(profile: profile, source: configuration.executable) else { return .init() }
        let record = BrowserLaunchRecord.read(profile: profile, identity: identity)
        let knownTimeZone = record != nil || identity.timeZone != nil || configuration.timeZone == nil
        let changed = identity.proxy != configuration.proxy || (knownTimeZone && (record?.timeZone ?? identity.timeZone) != configuration.timeZone)
        return .init(phase: closingPIDs.contains(identity.pid) ? .stopping : changed ? .restartRequired : knownTimeZone ? .running : .unverified, pid: identity.pid, usesCustomIcon: identity.executable != configuration.executable.path)
    }
    func open(configuration: PureBrowserConfiguration, profile: URL, page: String, launchExecutable: URL? = nil, accountLink: Bool = false, label: String? = nil, account: String? = nil) throws {
        let executable = launchExecutable ?? configuration.executable
        let existing = sessions[profile.path]
        let identity = observed(profile: profile, source: configuration.executable)
        if accountLink, existing?.process.isRunning == true || identity != nil {
            let arguments = identity?.arguments ?? existing?.process.arguments ?? []
            guard arguments.contains("--remote-debugging-port=0"), arguments.contains("--remote-debugging-address=127.0.0.1") else {
                throw AccountConnectionError.browser("首次接入需先关闭此独立浏览器，再从这里打开。原有浏览器资料会保留。")
            }
        }
        if let existing, existing.process.isRunning,
           existing.proxy != configuration.proxy || existing.timeZone != configuration.timeZone || existing.process.executableURL != executable {
            throw NSError(domain: "ManagedChrome", code: 1, userInfo: [NSLocalizedDescriptionKey: "代理、时区或浏览器图标已改变，请先关闭此浏览器，再重新打开以应用新设置。"])
        }
        let recorded = identity.flatMap { BrowserLaunchRecord.read(profile: profile, identity: $0) }
        if existing?.process.isRunning != true, let identity,
           identity.proxy != configuration.proxy || (recorded?.timeZone ?? identity.timeZone) != configuration.timeZone || identity.executable != executable.path {
            throw NSError(domain: "ManagedChrome", code: 2, userInfo: [NSLocalizedDescriptionKey: "浏览器标识或设置已更新，请先关闭此环境的浏览器，再重新打开。"])
        }
        if existing?.process.isRunning != true, identity == nil,
           let lock = try? FileManager.default.destinationOfSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path),
           let part = lock.split(separator: "-").last, let pid = Int32(part), pid > 1, kill(pid, 0) == 0 {
            throw NSError(domain: "ManagedChrome", code: 3, userInfo: [NSLocalizedDescriptionKey: "浏览器资料目录被其他进程占用，无法确认归属；请手动退出该浏览器。"])
        }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = executable
        process.environment = configuration.environment()
        let sessionID = UUID().uuidString
        let starting = existing?.process.isRunning != true && identity == nil
        // Chrome rewrites its prefs on exit, so the label is only written before a fresh launch.
        if starting, let label { ChromeProfileLabel.write(label, profile: profile, account: account) }
        process.arguments = configuration.arguments(profile: profile) + ["--cc-assistant-session-id=\(sessionID)", "--new-window"]
            + (label.map { ["--window-name=\($0)"] } ?? []) + [page]
        if accountLink { process.arguments! += ["--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0"] }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        if existing?.process.isRunning != true && identity == nil {
            sessions[profile.path] = Session(process: process, proxy: configuration.proxy, timeZone: configuration.timeZone)
            closingPIDs.remove(process.processIdentifier)
            let record = BrowserLaunchRecord(pid: process.processIdentifier, sessionID: sessionID, proxy: configuration.proxy, timeZone: configuration.timeZone)
            try? SubscriptionStorage.privateWrite(JSONEncoder().encode(record), to: BrowserLaunchRecord.file(profile: profile))
        }
    }
    func close(profile: URL) -> Bool {
        if let session = sessions[profile.path], session.process.isRunning {
            sessions[profile.path]?.closing = true
            session.process.terminate(); return true
        }
        guard let source = Self.executable, let identity = observed(profile: profile, source: source) else { return false }
        guard kill(identity.pid, SIGTERM) == 0 else { return false }
        closingPIDs.insert(identity.pid); return true
    }
}

/// Names the Chrome profile after the account, so the toolbar profile chip and window title say whose browser it is.
enum ChromeProfileLabel {
    /// Stable per-account hue so each account's browser is told apart at a glance; signed ARGB as Chrome stores it.
    static func themeColor(_ label: String) -> Int {
        let hue = Double(label.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 } % 360) / 360
        let color = NSColor(hue: hue, saturation: 0.55, brightness: 0.72, alpha: 1).usingColorSpace(.sRGB) ?? .gray
        let argb = (0xFF << 24) | (Int(color.redComponent * 255) << 16) | (Int(color.greenComponent * 255) << 8) | Int(color.blueComponent * 255)
        return Int(Int32(truncatingIfNeeded: argb))
    }
    static let markerKey = "cc_assistant_account"
    static func write(_ label: String, profile: URL, account: String? = nil) {
        let name = String(label.prefix(60))
        merge(profile.appendingPathComponent("Local State")) { root in
            var profileNode = root["profile"] as? [String: Any] ?? [:]
            var cache = profileNode["info_cache"] as? [String: Any] ?? [:]
            var entry = cache["Default"] as? [String: Any] ?? [:]
            entry["name"] = name; entry["is_using_default_name"] = false
            cache["Default"] = entry; profileNode["info_cache"] = cache; root["profile"] = profileNode
        }
        merge(profile.appendingPathComponent("Default/Preferences")) { root in
            var profileNode = root["profile"] as? [String: Any] ?? [:]
            profileNode["name"] = name; root["profile"] = profileNode
            var bar = root["bookmark_bar"] as? [String: Any] ?? [:]
            bar["show_on_all_tabs"] = true; root["bookmark_bar"] = bar
            var browser = root["browser"] as? [String: Any] ?? [:]
            var theme = browser["theme"] as? [String: Any] ?? [:]
            theme["user_color"] = themeColor(name); theme["color_variant"] = 1
            browser["theme"] = theme; root["browser"] = browser
        }
        if let account { pinAccountBookmark("👤 " + String(account.prefix(80)), profile: profile) }
    }
    /// Keeps one marked bookmark first on the bar; the user's own bookmarks are left as they are.
    static func pinAccountBookmark(_ title: String, profile: URL) {
        merge(profile.appendingPathComponent("Default/Bookmarks")) { root in
            var roots = root["roots"] as? [String: Any] ?? [:]
            func ids(_ node: Any?) -> [Int] {
                guard let node = node as? [String: Any] else { return [] }
                return [Int(node["id"] as? String ?? "") ?? 0] + ((node["children"] as? [Any]) ?? []).flatMap(ids)
            }
            let next = max(3, roots.values.flatMap(ids).max() ?? 0) + 1
            func folder(_ id: String, _ name: String) -> [String: Any] { ["id": id, "name": name, "type": "folder", "children": []] }
            var bar = roots["bookmark_bar"] as? [String: Any] ?? folder("1", "书签栏")
            var children = (bar["children"] as? [[String: Any]] ?? []).filter { ($0["meta_info"] as? [String: Any])?[markerKey] == nil }
            children.insert(["id": String(next), "name": title, "type": "url", "url": "https://claude.ai/", "meta_info": [markerKey: "1"]], at: 0)
            bar["children"] = children; roots["bookmark_bar"] = bar
            if roots["other"] == nil { roots["other"] = folder("2", "其他书签") }
            if roots["synced"] == nil { roots["synced"] = folder("3", "移动设备书签") }
            root["roots"] = roots; root["version"] = root["version"] ?? 1
            // Chrome rejects a stale checksum but accepts none.
            root.removeValue(forKey: "checksum")
        }
    }
    /// Best effort: an unreadable file is left alone rather than replaced.
    static func merge(_ file: URL, _ change: (inout [String: Any]) -> Void) {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file), data.count < 16 * 1024 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            root = object
        }
        change(&root)
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
    }
}
