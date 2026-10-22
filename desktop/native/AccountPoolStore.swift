import Foundation

enum AccountPoolStatus: String, Codable, CaseIterable {
    case available = "备用", inUse = "使用中", attention = "需处理", disabled = "已停用"
}
struct AccountPoolDraft: Equatable {
    var email = ""
    var label = ""
    var status: AccountPoolStatus = .available
    var subscription = ""
    var expiresAt: Date?
    var createdAt = Date()
    var notes = ""
}
struct AccountPoolRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var email: String
    var label: String
    var status: AccountPoolStatus
    var subscription: String
    var expiresAt: Date?
    var createdAt: Date
    var notes: String
    var updatedAt: Date
    var deletedAt: Date?
    var recordedAt: Date? = nil
    var identity: AccountIdentitySnapshot? = nil
    /// Set when the saved session came back 401; holds the status to restore once a read succeeds again.
    var sessionInvalidFrom: AccountPoolStatus? = nil
    var draft: AccountPoolDraft { .init(email: email, label: label, status: status, subscription: subscription, expiresAt: expiresAt, createdAt: createdAt, notes: notes) }
}

@MainActor final class AccountPoolStore {
    private struct State: Codable { var version = 1; var accounts: [AccountPoolRecord] = [] }
    static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Subscription Studio/accounts.json")
    }
    private static let limit = 4 * 1024 * 1024
    let fileURL: URL
    private(set) var records: [AccountPoolRecord] = []
    private(set) var loadError: String?
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFile
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        do {
            let handle = try FileHandle(forReadingFrom: self.fileURL); defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.limit + 1) ?? Data()
            guard data.count <= Self.limit else { throw SubscriptionFailure("账号资料超过大小限制") }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(State.self, from: data)
            guard state.version == 1 else { throw SubscriptionFailure("账号资料版本不受支持") }
            try Self.validate(state.accounts); records = state.accounts
        } catch { loadError = "账号资料读取失败，已停止写入以保留原文件。请先恢复备份或检查数据目录。" }
    }
    nonisolated static func email(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count <= 254, value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw SubscriptionFailure("请填写有效的账号邮箱。") }
        return value
    }
    private static func validate(_ rows: [AccountPoolRecord]) throws {
        guard rows.count <= 5000, Set(rows.map(\.id)).count == rows.count else { throw SubscriptionFailure("账号数量或记录标识不正确") }
        var emails = Set<String>()
        for row in rows {
            let normalized = try email(row.email)
            guard row.label.count <= 100, row.subscription.count <= 100, row.notes.count <= 4000,
                  row.createdAt.timeIntervalSince1970.isFinite, row.updatedAt.timeIntervalSince1970.isFinite,
                  row.recordedAt?.timeIntervalSince1970.isFinite != false,
                  row.expiresAt?.timeIntervalSince1970.isFinite != false, row.deletedAt?.timeIntervalSince1970.isFinite != false else {
                throw SubscriptionFailure("备注名 / 订阅类型最多 100 字，备注最多 4000 字，日期需有效。")
            }
            if let identity = row.identity {
                guard identity.email == normalized, identity.name?.count ?? 0 <= 100, identity.plan?.count ?? 0 <= 50,
                      identity.accountID?.count ?? 0 <= 128, identity.checkedAt.timeIntervalSince1970.isFinite,
                      identity.remoteCreatedAt?.timeIntervalSince1970.isFinite != false else { throw AccountConnectionError.badResponse }
                if let details = identity.details {
                    guard details.displayName?.count ?? 0 <= 100,
                          details.remoteUpdatedAt?.timeIntervalSince1970.isFinite != false,
                          details.verificationCompletedAt?.timeIntervalSince1970.isFinite != false,
                          details.organizations.count <= 50 else { throw AccountConnectionError.badResponse }
                    for org in details.organizations {
                        let values = [org.id, org.name, org.role, org.seatTier, org.analyticsPlan, org.planDisplayName, org.planDisplayLabel, org.rateLimitTier, org.billingType, org.billingIssue, org.accessBlock, org.subscriptionPause, org.apiDisabledReason].compactMap { $0 }
                        guard values.allSatisfy({ $0.count <= 200 && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }) else { throw AccountConnectionError.badResponse }
                    }
                }
            }
            if row.deletedAt == nil, !emails.insert(normalized).inserted { throw SubscriptionFailure("这个邮箱已经在号池中，请编辑已有记录。") }
        }
    }
    private func commit(_ rows: [AccountPoolRecord]) throws {
        if let loadError { throw SubscriptionFailure(loadError) }
        try Self.validate(rows)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(State(accounts: rows))
        guard data.count <= Self.limit else { throw SubscriptionFailure("账号资料超过 4 MiB，未保存本次修改。") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SubscriptionStorage.privateWrite(data, to: fileURL)
        records = rows
    }
    @discardableResult func save(_ draft: AccountPoolDraft, id: UUID? = nil, now: Date = Date()) throws -> AccountPoolRecord {
        let address = try Self.email(draft.email)
        if let id, !records.contains(where: { $0.id == id && $0.deletedAt == nil }) { throw SubscriptionFailure("该账号记录已不存在，未覆盖其他记录。") }
        var row = AccountPoolRecord(id: id ?? UUID(), email: address, label: draft.label.trimmingCharacters(in: .whitespacesAndNewlines), status: draft.status,
            subscription: draft.subscription.trimmingCharacters(in: .whitespacesAndNewlines), expiresAt: draft.expiresAt, createdAt: draft.createdAt,
            notes: draft.notes, updatedAt: now, deletedAt: nil)
        if let old = records.first(where: { $0.id == row.id }) { row.recordedAt = old.recordedAt }
        else { row.recordedAt = now }
        if let old = records.first(where: { $0.id == row.id && $0.email == address }) {
            row.identity = old.identity
            if row.status == old.status { row.sessionInvalidFrom = old.sessionInvalidFrom }
        }
        var next = records
        if let index = next.firstIndex(where: { $0.id == row.id }) { next[index] = row } else { next.append(row) }
        try commit(next); return row
    }
    @discardableResult func acceptIdentity(_ identity: AccountIdentitySnapshot, targetID: UUID? = nil, overwritePlan: Bool = true) throws -> AccountPoolRecord {
        let address = try Self.email(identity.email)
        guard address == identity.email else { throw AccountConnectionError.badResponse }
        let existing = targetID.flatMap { id in records.first { $0.id == id && $0.deletedAt == nil } }
            ?? records.first { $0.email.lowercased() == address && $0.deletedAt == nil }
        if let targetID, existing?.id != targetID || existing?.email.lowercased() != address { throw AccountConnectionError.mismatch }
        if existing == nil, records.contains(where: { $0.email.lowercased() == address }) {
            throw SubscriptionFailure("该邮箱已在回收站，请先还原账号后再接入。")
        }
        var row = existing ?? .init(id: UUID(), email: address, label: identity.name ?? "", status: .available,
                                   subscription: "", expiresAt: nil, createdAt: identity.remoteCreatedAt ?? Date(), notes: "", updatedAt: Date(), deletedAt: nil)
        if existing == nil { row.recordedAt = Date() }
        if let plan = identity.plan, overwritePlan || row.subscription.isEmpty || row.subscription == row.identity?.plan { row.subscription = plan }
        row.identity = identity; row.updatedAt = Date()
        if let previous = row.sessionInvalidFrom {
            if row.status == .attention { row.status = previous }
            row.sessionInvalidFrom = nil
        }
        var next = records
        if let index = next.firstIndex(where: { $0.id == row.id }) { next[index] = row } else { next.append(row) }
        try commit(next); return row
    }
    func markSessionInvalid(_ id: UUID, now: Date = Date()) throws {
        guard let index = records.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        var next = records
        if next[index].sessionInvalidFrom == nil { next[index].sessionInvalidFrom = next[index].status }
        next[index].status = .attention; next[index].updatedAt = now; try commit(next)
    }
    func delete(_ id: UUID, now: Date = Date()) throws {
        guard let index = records.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw SubscriptionFailure("账号记录不存在。") }
        var next = records; next[index].deletedAt = now; next[index].updatedAt = now; try commit(next)
    }
    func restore(_ id: UUID, now: Date = Date()) throws {
        guard let index = records.firstIndex(where: { $0.id == id && $0.deletedAt != nil }) else { throw SubscriptionFailure("回收站记录不存在。") }
        var next = records; next[index].deletedAt = nil; next[index].updatedAt = now; try commit(next)
    }
    func backupData() throws -> Data {
        if let loadError { throw SubscriptionFailure(loadError) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(State(accounts: records))
    }
    @discardableResult func importData(_ data: Data) throws -> Int {
        guard data.count <= Self.limit else { throw SubscriptionFailure("文件超过 4 MiB，未导入。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(State.self, from: data)
        guard state.version == 1 else { throw SubscriptionFailure("号池文件版本不受支持。") }
        try Self.validate(state.accounts)
        var next = records
        for row in state.accounts {
            if let current = next.first(where: { $0.id == row.id }) {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(current) == encoder.encode(row) else { throw SubscriptionFailure("文件含同一账号的不同版本，未导入；已有记录未覆盖。") }
            } else { next.append(row) }
        }
        let count = next.count - records.count
        try commit(next); return count
    }
}
