import Foundation

struct AccountConnection: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case browser, session }
    var version = 1
    var generation = UUID()
    let kind: Kind
    let email: String
    var profileID: UUID?
    var sessionKey: String?
}

// Separate from accounts.json and its export. Never accesses the system Keychain.
@MainActor final class AccountConnectionStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".json") }
    func exists(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: file(id).path) }
    private func safeDirectory() throws {
        if FileManager.default.fileExists(atPath: directory.path),
           try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw SubscriptionFailure("会话目录异常，已停止访问。") }
    }
    func load(_ id: UUID) throws -> AccountConnection {
        try safeDirectory()
        let url = file(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AccountConnectionError.noConnection }
        do {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AccountConnectionError.badResponse }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 16385) ?? Data()
            guard data.count <= 16384 else { throw AccountConnectionError.badResponse }
            let value = try JSONDecoder().decode(AccountConnection.self, from: data)
            try validate(value); return value
        } catch { throw SubscriptionFailure("本机关联无法读取，请重新接入。已有账号资料保留。") }
    }
    private func validate(_ value: AccountConnection) throws {
        guard value.version == 1, try AccountPoolStore.email(value.email) == value.email else { throw AccountConnectionError.badResponse }
        switch value.kind {
        case .session:
            guard value.profileID == nil, let key = value.sessionKey, try AccountIdentityParser.sessionKey(key) == key else { throw AccountConnectionError.invalidSession }
        case .browser:
            guard value.profileID != nil, value.sessionKey == nil else { throw AccountConnectionError.badResponse }
        }
    }
    func save(_ value: AccountConnection, for id: UUID) throws {
        try validate(value); try safeDirectory()
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: file(id).path)) != nil {
            throw SubscriptionFailure("会话文件异常，已停止写入。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var directory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try SubscriptionStorage.privateWrite(JSONEncoder().encode(value), to: file(id))
        var url = file(id); try url.setResourceValues(values)
    }
    func remove(_ id: UUID) throws {
        try safeDirectory()
        if exists(id) { try FileManager.default.removeItem(at: file(id)) }
    }
}
