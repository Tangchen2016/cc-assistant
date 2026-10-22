import SwiftUI

@MainActor final class AccountPoolModel: ObservableObject {
    let store: AccountPoolStore
    @Published private(set) var records: [AccountPoolRecord]
    @Published var query = ""
    @Published var filter: AccountPoolStatus?
    @Published var showDeleted = false
    @Published var showEditor = false
    @Published var showConnection = false
    @Published private(set) var refreshing = Set<UUID>()
    @Published private(set) var connectionMessages: [UUID: String] = [:]
    let connectionFlow = AccountConnectionFlow()
    let connections: AccountConnectionStore
    @Published var draft = AccountPoolDraft()
    @Published private(set) var editorError = ""
    @Published private(set) var notice = ""
    private var editingID: UUID?
    private var originalDraft = AccountPoolDraft()
    init(store: AccountPoolStore? = nil) {
        let store = store ?? AccountPoolStore(); self.store = store; records = store.records
        connections = AccountConnectionStore(directory: store.fileURL.deletingLastPathComponent().appendingPathComponent("private-sessions", isDirectory: true))
    }
    var readAccountBrowser: ((AccountPoolRecord, AccountConnection) async throws -> AccountIdentitySnapshot)?
    var accountSessionProxy: ((String) throws -> String?)?
    var hasUnsavedChanges: Bool { (showEditor && draft != originalDraft) || (showConnection && connectionFlow.hasPendingInput) || (showBatch && (!batchInput.isEmpty || batchBusy)) }
    var editorTitle: String { editingID == nil ? "新增账号" : "编辑账号" }
    var activeRecords: [AccountPoolRecord] { records.filter { $0.deletedAt == nil } }
    var deletedCount: Int { records.filter { $0.deletedAt != nil }.count }
    var visibleRecords: [AccountPoolRecord] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { row in
            (showDeleted ? row.deletedAt != nil : row.deletedAt == nil) && (filter == nil || row.status == filter) &&
            (search.isEmpty || [row.email, row.label, row.subscription, row.notes].contains { $0.localizedStandardContains(search) })
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
    static func daysUntilExpiry(_ date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }
    var expiringSoonCount: Int { activeRecords.filter { $0.expiresAt.map { (0...7).contains(Self.daysUntilExpiry($0)) } ?? false }.count }
    func reportEnvironmentError(_ error: Error) { notice = error.localizedDescription }
    func create() {
        guard store.loadError == nil else { return }
        editingID = nil; draft = .init(); originalDraft = draft; editorError = ""; showEditor = true
    }
    func edit(_ row: AccountPoolRecord) {
        guard row.deletedAt == nil, store.loadError == nil else { return }
        editingID = row.id; draft = row.draft; originalDraft = draft; editorError = ""; showEditor = true
    }
    func save() {
        do {
            let previous = records.first { $0.id == editingID }
            let saved = try store.save(draft, id: editingID); records = store.records; showEditor = false; notice = "账号记录已保存。"
            if let previous, previous.email != saved.email {
                do { try connections.remove(previous.id); connectionMessages[previous.id] = "邮箱已改变，请重新接入。" }
                catch { connectionMessages[previous.id] = "邮箱已改变，原关联不可使用；请重新接入。" }
            }
        } catch { editorError = error.localizedDescription }
    }
    func cancel() { showEditor = false; editorError = "" }
    func beginConnection(_ intent: AccountConnectionIntent, row: AccountPoolRecord? = nil, email: String = "") {
        guard store.loadError == nil else { return }
        showDeleted = false; connectionFlow.begin(intent, row: row, email: email); showConnection = true
    }
    func cancelConnection() { connectionFlow.cancel(); showConnection = false }
    func acceptConnection() {
        guard let value = connectionFlow.candidate, !connectionFlow.busy else { return }
        do {
            let saved = try store.acceptIdentity(value.identity, targetID: connectionFlow.targetID)
            records = store.records
            do {
                if value.connection.kind == .browser || connectionFlow.rememberSession { try connections.save(value.connection, for: saved.id) }
                else { try connections.remove(saved.id) }
            } catch {
                connectionMessages[saved.id] = "资料已入库，关联保存失败，请重新接入。"
                connectionFlow.showError(SubscriptionFailure("账号资料已入库，但本机关联保存失败。可以重试；不会重复创建账号。")); return
            }
            connectionMessages[saved.id] = value.connection.kind == .browser ? "已关联独立浏览器" : connectionFlow.rememberSession ? "Session 刚刚核验" : "本次识别，未保留 Session"
            notice = "已将 \(saved.email) 接入号池。"; query = ""; filter = nil; cancelConnection()
        } catch { connectionFlow.showError(error) }
    }
    func connectionText(_ row: AccountPoolRecord) -> String {
        connectionMessages[row.id] ?? (connections.exists(row.id) ? "已关联 · 可刷新" : row.identity == nil ? "尚未关联" : "已识别 · 未关联本机会话")
    }
    func disconnect(_ row: AccountPoolRecord) {
        do { try connections.remove(row.id); connectionMessages[row.id] = "已解除本机关联"; notice = "账号记录保留，已移除本机关联。"}
        catch { notice = "无法解除关联，请检查本机资料目录。" }
    }
    func refresh(_ row: AccountPoolRecord) { refreshBatch([row]) }
    /// Marks the row busy; false when it is already refreshing or no longer refreshable.
    private func beginRefresh(_ row: AccountPoolRecord) -> Bool {
        guard !refreshing.contains(row.id), store.loadError == nil,
              records.contains(where: { $0.id == row.id && $0.email == row.email && $0.deletedAt == nil }) else { return false }
        refreshing.insert(row.id); connectionMessages[row.id] = "排队中…"; return true
    }
    /// ponytail: fixed cap of 3 in flight (each account = 2 sequential requests); raise or add per-request spacing if claude.ai throttles.
    static let refreshConcurrency = 3
    func refreshBatch(_ rows: [AccountPoolRecord]) {
        let queue = rows.filter(beginRefresh)
        guard !queue.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                var pending = queue.makeIterator()
                for _ in 0..<Self.refreshConcurrency { if let row = pending.next() { group.addTask { await self.performRefresh(row) } } }
                while await group.next() != nil { if let row = pending.next() { group.addTask { await self.performRefresh(row) } } }
            }
        }
    }
    private func performRefresh(_ row: AccountPoolRecord) async {
        connectionMessages[row.id] = "正在刷新…"
        do {
            defer { refreshing.remove(row.id) }
            do {
                var connection = try connections.load(row.id)
                guard connection.email == row.email else { throw AccountConnectionError.mismatch }
                let generation = connection.generation
                let identity: AccountIdentitySnapshot
                switch connection.kind {
                case .session:
                    guard let key = connection.sessionKey else { throw AccountConnectionError.noConnection }
                    let proxy: String?
                    if let accountSessionProxy { proxy = try accountSessionProxy(row.email) } else { proxy = try connectionFlow.sessionProxy() }
                    let value = try await connectionFlow.sessionReader(key, proxy)
                    identity = value.identity; connection.sessionKey = value.sessionKey
                case .browser:
                    if let readAccountBrowser {
                        identity = try await readAccountBrowser(row, connection)
                    } else {
                    guard let profile = connection.profileID, connectionFlow.browserProfile?() == profile, let reader = connectionFlow.browserReader else {
                        throw AccountConnectionError.browser("当前独立环境与关联不同，请重新登录后接入，或使用 Session 重新关联。")
                    }
                    identity = try await reader()
                    guard connectionFlow.browserProfile?() == profile else { throw AccountConnectionError.changed }
                    }
                }
                guard records.contains(where: { $0.id == row.id && $0.email == row.email && $0.deletedAt == nil }),
                      try connections.load(row.id).generation == generation else { throw AccountConnectionError.changed }
                guard identity.email == row.email,
                      row.identity?.accountID == nil || identity.accountID == row.identity?.accountID else { throw AccountConnectionError.mismatch }
                let saved = try store.acceptIdentity(identity, targetID: row.id, overwritePlan: false); records = store.records
                connection.generation = UUID(); try connections.save(connection, for: row.id)
                connectionMessages[row.id] = identity.plan != nil && saved.subscription != identity.plan ? "已核验，手动套餐记录保留" : "刚刚核验"
            } catch {
                if connections.exists(row.id) {
                    connectionMessages[row.id] = error.localizedDescription
                    // Only 401 proves the credential is dead; 403 / network don't.
                    if error as? AccountConnectionError == .unauthorized {
                        try? store.markSessionInvalid(row.id); records = store.records
                    }
                } else { connectionMessages[row.id] = "尚未关联" }
            }
        }
    }
    // MARK: Batch Session import
    struct BatchItem: Identifiable {
        enum State { case reading, ready(AccountSessionReading), saved(String), failed(String) }
        let id = UUID()
        let key: String
        var state: State = .reading
        var reading: AccountSessionReading? { if case .ready(let value) = state { return value }; return nil }
    }
    @Published var showBatch = false
    @Published var batchInput = ""
    @Published private(set) var batchItems: [BatchItem] = []
    @Published private(set) var batchBusy = false
    var batchReadyCount: Int { batchItems.filter { $0.reading != nil }.count }
    func beginBatch() { guard store.loadError == nil else { return }; batchInput = ""; batchItems = []; showBatch = true }
    func cancelBatch() { showBatch = false; batchInput = ""; batchItems = [] }
    /// One sessionKey per line (a leading "sessionKey=" is fine); duplicates collapse.
    func readBatch() {
        guard !batchBusy else { return }
        var seen = Set<String>(), items: [BatchItem] = []
        for line in batchInput.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let key = try? AccountIdentityParser.sessionKey(text) else { items.append(.init(key: "", state: .failed("格式无效：" + text.prefix(12) + "…"))); continue }
            if seen.insert(key).inserted { items.append(.init(key: key)) }
        }
        guard items.count <= 200 else { notice = "一次最多导入 200 个 Session。"; return }
        batchItems = items
        let proxy: String?
        do { proxy = try connectionFlow.sessionProxy() } catch { notice = error.localizedDescription; return }
        let jobs = items.filter { if case .reading = $0.state { return true }; return false }
        guard !jobs.isEmpty else { return }
        batchBusy = true
        let reader = connectionFlow.sessionReader
        Task {
            defer { batchBusy = false }
            await withTaskGroup(of: (UUID, BatchItem.State).self) { group in
                var pending = jobs.makeIterator()
                func next() {
                    guard let job = pending.next() else { return }
                    group.addTask {
                        do { return (job.id, .ready(try await reader(job.key, proxy))) }
                        catch { return (job.id, .failed(error.localizedDescription)) }
                    }
                }
                for _ in 0..<Self.refreshConcurrency { next() }
                while let (id, state) = await group.next() {
                    if let index = batchItems.firstIndex(where: { $0.id == id }) { batchItems[index].state = state }
                    next()
                }
            }
            // Two keys for one account: keep the first.
            var emails = Set<String>()
            for index in batchItems.indices {
                guard let email = batchItems[index].reading?.identity.email else { continue }
                if !emails.insert(email).inserted { batchItems[index].state = .failed("与上方重复：\(email)") }
            }
        }
    }
    func saveBatch() {
        guard !batchBusy else { return }
        var saved = 0, failed = 0
        for index in batchItems.indices {
            guard let reading = batchItems[index].reading else { continue }
            do {
                let row = try store.acceptIdentity(reading.identity)
                try connections.save(.init(kind: .session, email: row.email, sessionKey: reading.sessionKey), for: row.id)
                connectionMessages[row.id] = "Session 刚刚核验"; saved += 1
                batchItems[index].state = .saved(row.email)
            } catch { batchItems[index].state = .failed(error.localizedDescription); failed += 1 }
        }
        records = store.records
        notice = "批量导入完成：\(saved) 个入库" + (failed > 0 ? "，\(failed) 个失败" : "") + "。"
        if failed == 0 { cancelBatch() }
    }
    var invalidSessionCount: Int { activeRecords.filter { $0.sessionInvalidFrom != nil }.count }
    var refreshableRecords: [AccountPoolRecord] { activeRecords.filter { connections.exists($0.id) } }
    var nearLimitCount: Int { activeRecords.filter { ($0.identity?.usage?.highest ?? 0) >= 80 }.count }
    func refreshAll() { refreshBatch(refreshableRecords) }
    /// Panel-open refresh; ponytail: 5 min floor so repeated opens don't hammer claude.ai.
    func refreshStaleUsage(maxAge: TimeInterval = 300) {
        refreshBatch(refreshableRecords.filter { Date().timeIntervalSince($0.identity?.checkedAt ?? .distantPast) > maxAge })
    }
    func importData(_ data: Data) throws {
        let count = try store.importData(data); records = store.records; notice = "已导入 \(count) 条新记录。"
    }
    func delete(_ row: AccountPoolRecord) {
        do { try store.delete(row.id); records = store.records; notice = "已移入回收站，可以还原。" }
        catch { notice = error.localizedDescription }
    }
    func restore(_ row: AccountPoolRecord) {
        do { try store.restore(row.id); records = store.records; notice = "账号记录已还原。" }
        catch { notice = error.localizedDescription }
    }
}
