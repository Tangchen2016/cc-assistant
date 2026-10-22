import Foundation

struct SubscriptionFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum SubscriptionStorage {
    static func privateWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
            attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw SubscriptionFailure("无法创建资料文件。") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: url) }
    }
}
