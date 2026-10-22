import Foundation

@MainActor final class SubscriptionStorage: ObservableObject {
    @Published private(set) var state = SubscriptionState()
    @Published private(set) var error: String?
    let directory: URL
    private var writable = true
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Subscription Studio")
        let file = self.directory.appendingPathComponent("profiles.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= 16 * 1024 * 1024 else { throw SubscriptionFailure("配置文件过大") }
            let decoded = try JSONDecoder().decode(SubscriptionState.self, from: data)
            guard decoded.version == 1, Set(decoded.records.map(\.id)).count == decoded.records.count, decoded.records.allSatisfy({ Self.valid($0.id, length: 32) && Self.valid($0.manageKey, length: 64) && Self.valid($0.downloadKey, length: 64) }) else { throw SubscriptionFailure("配置格式无效") }
            state = decoded
            let backup = self.directory.appendingPathComponent("profiles.before-swift.json")
            if !FileManager.default.fileExists(atPath: backup.path) { try Self.privateWrite(data, to: backup) }
            var migrated = decoded
            if try StaticProxyLibrary.migrate(&migrated) {
                let before = self.directory.appendingPathComponent("profiles.before-static-nodes.json")
                if !FileManager.default.fileExists(atPath: before.path) { try Self.privateWrite(data, to: before) }
                try commit(migrated)
            }
        } catch { writable = false; self.error = "无法读取或迁移原有配置，已禁止覆盖。请保留 profiles.json 并检查文件。" }
    }
    nonisolated static func valid(_ text: String, length: Int) -> Bool { text.count == length && text.allSatisfy { "0123456789abcdef".contains($0) } }
    nonisolated static func privateWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw SubscriptionFailure("无法创建配置文件") }
        defer { try? FileManager.default.removeItem(at: tmp) }
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) } else { try FileManager.default.moveItem(at: tmp, to: url) }
    }
    func commit(_ next: SubscriptionState) throws {
        guard writable else { throw SubscriptionFailure(error ?? "配置只读") }
        try Self.privateWrite(JSONEncoder().encode(next), to: directory.appendingPathComponent("profiles.json"))
        state = next
    }
    func saveDraft(_ profile: SubscriptionProfile?, currentId: String?, addressMode: SubscriptionAddressMode? = nil) throws { var next = state; if var profile { try StaticProxyLibrary.link(&profile, state: &next); next.draft = profile; next.draftAddressMode = addressMode ?? next.draftAddressMode } else { next.draft = nil; next.draftAddressMode = nil }; next.currentId = currentId; try commit(next) }
    func save(_ profile: SubscriptionProfile, id: String?, addressMode: SubscriptionAddressMode? = nil) throws -> SubscriptionRecord {
        var next = state
        var profile = profile
        try StaticProxyLibrary.link(&profile, state: &next)
        try SubscriptionCore.validate(profile)
        var record: SubscriptionRecord
        if let id { guard let existing = next.records.first(where: { $0.id == id }) else { throw SubscriptionFailure("原配置不存在") }; record = existing; record.profile = profile; record.updatedAt = Date().timeIntervalSince1970 * 1000 }
        else { record = SubscriptionRecord(id: try SubscriptionCore.token(16), manageKey: try SubscriptionCore.token(32), downloadKey: try SubscriptionCore.token(32), profile: profile, updatedAt: Date().timeIntervalSince1970 * 1000) }
        if let addressMode { record.addressMode = profile.isShadowrocket ? .remote : addressMode }
        next.draftAddressMode = record.preferredAddressMode
        next.records.removeAll { $0.id == record.id }; next.records.insert(record, at: 0); next.currentId = record.id; next.draft = profile
        try commit(next); return record
    }
    func addressMode(_ id: String, value: SubscriptionAddressMode) throws {
        var next = state
        guard let index = next.records.firstIndex(where: { $0.id == id }) else { throw SubscriptionFailure("配置已删除") }
        next.records[index].addressMode = next.records[index].profile.isShadowrocket ? .remote : value
        if next.currentId == id { next.draftAddressMode = next.records[index].preferredAddressMode }
        try commit(next)
    }
    func remote(_ id: String, value: SubscriptionRemote?) throws { var next = state; guard let index = next.records.firstIndex(where: { $0.id == id }) else { throw SubscriptionFailure("配置已删除") }; next.records[index].remote = value; try commit(next) }
    func remove(_ id: String) throws { var next = state; guard let entry = next.records.first(where: { $0.id == id }), entry.remote == nil else { throw SubscriptionFailure("请先停用远程订阅再删除本机配置") }; next.records.removeAll { $0.id == id }; if next.currentId == id { next.currentId = nil; next.draft = nil }; try commit(next) }
}
