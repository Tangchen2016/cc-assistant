import Cocoa
import SwiftUI
import Yams
import Network

@MainActor final class SubscriptionModel: ObservableObject {
    let storage: SubscriptionStorage
    let server = SubscriptionServer()
    @Published var profile = SubscriptionProfile.empty
    @Published var currentId: String?
    @Published var source: SubscriptionSource?
    @Published var stage = "list"
    @Published var addressMode: SubscriptionAddressMode = .remote
    @Published var selectedGroup = 0
    @Published var busy = false
    @Published var message = ""
    @Published var error = ""
    @Published var showSource = false
    @Published var showFixed = false
    @Published var showGuide = false
    @Published var qrRecord: SubscriptionRecord?
    @Published var qrMode: SubscriptionMobileImport.Mode = .nodes
    @Published var client = "static"
    @Published var showStaticNodeEditor = false
    @Published var staticNodeName = ""
    @Published var staticNodeURL = ""
    @Published var revealStaticNodeURL = false
    @Published var deletingStaticNodeId: String?
    @Published var clashOverrideLink: String?
    private var editingStaticNodeId: String?
    private var staticLinkGroup: Int?
    @Published var search = ""
    @Published var onlyUS = false
    @Published var deleteId: String?
    @Published var delays: [String: String] = [:]
    @Published var measuring = false
    @Published private(set) var lineRunning = false
    @Published private(set) var lineStatus = ""
    enum Gate: Equatable { case idle, checking, open(String), blocked(String, exit: String?) }
    /// Fail-closed gate on the built-in proxy: requests pass only while the exit equals the marked IP.
    @Published private(set) var gate: Gate = .idle
    /// Exit seen by the last gate probe, e.g. "107.191.58.141 · US".
    @Published private(set) var gateExit: String?
    /// Live connections through the built-in proxy, refreshed every 2s while it runs.
    @Published private(set) var connections: [LineEngine.Connection] = []
    @Published private(set) var closedConnections: [LineEngine.Connection] = []
    private var connectionTask: Task<Void, Never>?
    var markedIP: () -> String? = { nil }
    private var gateTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    @Published var loginEnabled = false
    @Published private(set) var loginMessage = ""
    private let login = LoginItems()
    private var syncTask: Task<Void, Never>?
    private var syncing = Set<String>()
    init(storage: SubscriptionStorage? = nil) { let value = storage ?? SubscriptionStorage(); self.storage = value; if value.staticNodes.isEmpty && value.state.records.contains(where: { !$0.profile.isShadowrocket }) { client = "clash" }; loginEnabled = login.state(action: "state")["enabled"] as? Bool ?? false; error = value.error ?? "" }
    var records: [SubscriptionRecord] { storage.state.records }
    var staticNodes: [StaticProxyNode] { storage.staticNodes }
    var visibleRecords: [SubscriptionRecord] { records.filter { $0.profile.isShadowrocket == (client == "shadowrocket") } }
    func selectClient(_ value: String) { guard !busy, value != client else { return }; draft(); client = value; stage = "list"; error = ""; message = "" }
    /// Shadowrocket lines are static-IP lines; they open from the node card and return to it.
    func shadowrocketRecord(for node: StaticProxyNode) -> SubscriptionRecord? { records.first { $0.profile.isShadowrocket && $0.profile.groups.contains { $0.staticNodeId == node.id } } }
    var current: SubscriptionRecord? { records.first { $0.id == currentId } }
    var hasUnfinishedDraft: Bool {
        guard let draft = storage.state.draft else { return false }
        let saved = records.first { $0.id == storage.state.currentId }
        return draft != saved?.profile || storage.state.draftAddressMode.map { $0 != saved?.preferredAddressMode } == true
    }
    var guide: String { guard let url = Bundle.main.url(forResource: "static-proxy-ai-setup", withExtension: "md") else { return "部署说明资源缺失" }; return (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取部署说明" }
    func start() {
        loginEnabled = login.state(action: "state")["enabled"] as? Bool ?? false
        server.download = { [weak self] id, key in
            guard let self, let record = self.records.first(where: { $0.id == id }), Self.equalSecret(key, record.downloadKey) else { throw SubscriptionFailure("订阅不存在") }
            guard !record.profile.isShadowrocket else { throw SubscriptionFailure("手机线路请使用远程节点订阅地址") }
            let profile = try self.storage.resolved(record.profile)
            let source = try await SubscriptionNetwork.fetch(profile.sourceUrl)
            let yaml = try SubscriptionCore.transform(source.config, profile: profile)
            return (yaml, record.profile.name, source.userInfo)
        }
        server.overrideScript = { [weak self] id, key in
            guard let self, let node = self.staticNodes.first(where: { $0.id == id }), let saved = node.overrideKey, Self.equalSecret(key, saved) else { throw SubscriptionFailure("覆写不存在") }
            return try StaticProxyLibrary.clashOverride(node)
        }
        server.start()
        if LineEngine.enabled, let line = UserDefaults.standard.string(forKey: Self.activeLineKey) { Task { await startLine(line) } }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for record in self.records where record.remote != nil { try? await self.publish(record.id) }
                try? await Task.sleep(nanoseconds: 900_000_000_000)
            }
        }
    }
    func stop() { syncTask?.cancel(); server.stop() }
    static let activeLineKey = "claudeLine.activeRecord"
    var lineRecords: [SubscriptionRecord] { records.filter { !$0.profile.isShadowrocket } }
    /// Run a saved line in the bundled engine so browsers need no local Clash.
    func startLine(_ id: String) async {
        guard let record = lineRecords.first(where: { $0.id == id }) else { lineRunning = false; lineStatus = "请选择已保存的线路"; return }
        lineStatus = "正在启动内置代理…"
        do {
            let key = "\(record.id)-\(record.updatedAt)"
            if !LineEngine.isRunning(key: key) {
                let profile = try storage.resolved(record.profile)
                let source = try await SubscriptionNetwork.fetch(profile.sourceUrl)
                let yaml = try SubscriptionCore.transform(source.config, profile: profile)
                try await LineEngine.start(yaml: yaml, group: Self.lineGroup(profile), key: key)
            }
            UserDefaults.standard.set(id, forKey: Self.activeLineKey)
            lineRunning = true; lineStatus = "「\(record.profile.name)」运行中 · \(LineEngine.address)"
            startGate()
        } catch { lineRunning = false; lineStatus = error.localizedDescription }
    }
    func stopLine() { stopGate(); LineEngine.stop(); UserDefaults.standard.removeObject(forKey: Self.activeLineKey); lineRunning = false; lineStatus = "内置代理已停止" }

    /// Verify now: probe the exit through the line, then open or close the gate.
    func verifyGate() async {
        guard lineRunning else { return }
        if case .open = gate {} else { gate = .checking }
        let probe = await Task.detached { LineEngine.probeExit() }.value
        guard lineRunning else { return }
        gateExit = probe.ip.map { ip in probe.country.map { "\(ip) · \($0)" } ?? ip }
        let decision = LineEngine.gateDecision(exit: probe.ip, marked: markedIP())
        let applied = await Task.detached { LineEngine.setGate(open: decision.open) }.value
        gate = decision.open && applied ? .open(decision.reason) : .blocked(applied ? (probe.error ?? decision.reason) : "无法切换拦截开关，已拦截", exit: probe.ip)
        if !applied { _ = await Task.detached { LineEngine.setGate(open: false) }.value }
        TrafficLog.append("GATE", "\(decision.open && applied ? "open" : "blocked") exit=\(probe.ip ?? "-") country=\(probe.country ?? "-") marked=\(markedIP() ?? "-") \(probe.error ?? decision.reason)")
    }
    // ponytail: 60s poll + immediate re-check on network change / wake; per-request probing would add a round trip to every request.
    private func startGate() {
        stopGate()
        connectionTask = Task { [weak self] in
            var open: [String: LineEngine.Connection] = [:]
            while !Task.isCancelled {
                let now = await Task.detached { LineEngine.connections() }.value
                let ids = Set(now.map(\.id))
                // A connection that disappeared has closed: keep it for tracing and log its final summary.
                if let self { self.closedConnections = LineEngine.retainClosed(self.closedConnections, adding: open.values.filter { !ids.contains($0.id) }.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }) }
                for (id, row) in open where !ids.contains(id) {
                    let seconds = row.start.map { Int(Date().timeIntervalSince($0)) } ?? 0
                    TrafficLog.append("CONN", "\(row.host) remote=\(row.destination.isEmpty ? "-" : row.destination) chain=\(row.chain) rule=\(row.rule) up=\(row.upload) down=\(row.download) duration=\(seconds)s")
                }
                open = Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0) })
                self?.connections = now
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        gateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.verifyGate()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        let monitor = NWPathMonitor()
        var first = true
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                if first { first = false; return }  // initial callback, not a change
                await self?.recheckAfterChange()
            }
        }
        monitor.start(queue: .global(qos: .utility)); pathMonitor = monitor
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.recheckAfterChange() }
        }
    }
    /// Network changed or Mac woke: close first, then verify, so nothing passes on an unverified path.
    private func recheckAfterChange() async {
        guard lineRunning else { return }
        gate = .checking
        TrafficLog.append("GATE", "closed for re-check (network change or wake)")
        _ = await Task.detached { LineEngine.setGate(open: false) }.value
        await verifyGate()
    }
    private func stopGate() {
        gateTask?.cancel(); gateTask = nil
        connectionTask?.cancel(); connectionTask = nil; connections = []
        pathMonitor?.cancel(); pathMonitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
        gate = .idle; gateExit = nil
    }
    /// The group Claude traffic is routed to; the dedicated browser sends everything there.
    var missingRecommendedRules: Int {
        ClaudeRules.rules(group: "", mobile: profile.isShadowrocket).filter { entry in !profile.rules.contains { $0.type == entry.type && $0.value.lowercased() == entry.value } }.count
    }
    /// Appends any missing recommended rule, routed to the group Claude already uses.
    func addRecommendedRules() {
        guard !profile.groups.isEmpty else { return }
        let group = Self.lineGroup(profile)
        let missing = ClaudeRules.rules(group: group, mobile: profile.isShadowrocket).filter { entry in !profile.rules.contains { $0.type == entry.type && $0.value.lowercased() == entry.value } }
        profile.rules.append(contentsOf: missing.prefix(max(0, 100 - profile.rules.count)))
        draft()
    }
    nonisolated static func lineGroup(_ profile: SubscriptionProfile) -> String {
        profile.rules.first { $0.value == "claude.ai" }?.group ?? profile.groups[0].name
    }
    static func equalSecret(_ a: String, _ b: String) -> Bool { guard a.utf8.count == b.utf8.count else { return false }; return zip(a.utf8, b.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0 }
    func perform(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true; error = ""; message = ""
        Task { do { try await operation() } catch { self.error = error.localizedDescription }; self.busy = false; self.objectWillChange.send() }
    }
    func draft() { guard stage != "list" else { return }; do { try storage.saveDraft(profile, currentId: currentId, addressMode: addressMode) } catch { self.error = "草稿保存失败：" + error.localizedDescription } }
    func create() { currentId = nil; addressMode = .remote; profile = client == "shadowrocket" ? .mobile : .empty; source = nil; selectedGroup = 0; showSource = false; showFixed = false; stage = profile.isShadowrocket ? "configure" : "source"; error = ""; draft() }
    func resume() { guard let saved = storage.state.draft else { return }; do { profile = try storage.resolved(saved) } catch { self.error = error.localizedDescription; return }; client = saved.isShadowrocket ? "shadowrocket" : "clash"; currentId = storage.state.currentId; addressMode = saved.isShadowrocket ? .remote : storage.state.draftAddressMode ?? current?.preferredAddressMode ?? .remote; selectedGroup = 0; source = nil; showFixed = false; stage = saved.isShadowrocket ? "configure" : "source" }
    func open(_ record: SubscriptionRecord) {
        do { profile = try storage.resolved(record.profile) } catch { self.error = error.localizedDescription; return }; currentId = record.id; addressMode = record.preferredAddressMode; selectedGroup = 0; source = nil; showFixed = false; stage = "configure"; draft()
        client = profile.isShadowrocket ? "shadowrocket" : "clash"
        if profile.isShadowrocket { return }
        perform { self.source = try await SubscriptionNetwork.fetch(record.profile.sourceUrl) }
    }
    func setExitSource(_ fixed: Bool) {
        guard profile.groups.indices.contains(selectedGroup), (profile.groups[selectedGroup].fixedExit != nil) != fixed else { return }
        profile.groups[selectedGroup].fixedExit = fixed ? "" : nil
        profile.groups[selectedGroup].staticNodeId = nil
        if !fixed { profile.groups[selectedGroup].chain = nil }
        showFixed = false; draft()
    }
    func setChainEnabled(_ enabled: Bool) {
        guard profile.groups.indices.contains(selectedGroup), (profile.groups[selectedGroup].chain != nil) != enabled else { return }
        guard !enabled || profile.groups[selectedGroup].fixedExit != nil else { return }
        profile.groups[selectedGroup].chain = enabled ? .init(entry: SubscriptionCore.autoChainEntry) : nil
        draft()
    }
    static func validateEditorSetup(_ profile: SubscriptionProfile) throws {
        if profile.groups.contains(where: { $0.fixedExit == nil && $0.chain != nil }) {
            throw SubscriptionFailure("订阅节点使用普通规则组即可。请改为普通规则组，或将最终出口切换为静态IP节点。")
        }
    }
    func inspect() { perform { let value = try await SubscriptionNetwork.fetch(self.profile.sourceUrl); self.source = value; if self.currentId == nil && self.profile.name == "Claude 专属订阅" { self.profile.name = "增强-" + (value.sourceName ?? "源订阅") }; self.stage = "configure"; self.draft() } }
    func review() { do { profile = try storage.resolved(profile); try Self.validateEditorSetup(profile); try SubscriptionCore.validate(profile); guard let source else { throw SubscriptionFailure("请先刷新节点，核对所选前置和出口") }; _ = try SubscriptionCore.transform(source.config, profile: profile); stage = "review"; error = ""; draft() } catch { self.error = error.localizedDescription } }
    func save() { perform {
        self.profile = try self.storage.resolved(self.profile)
        try Self.validateEditorSetup(self.profile)
        try SubscriptionCore.validate(self.profile)
        var source: SubscriptionSource?
        if !self.profile.isShadowrocket { source = try await SubscriptionNetwork.fetch(self.profile.sourceUrl); _ = try SubscriptionCore.transform(source!.config, profile: self.profile) }
        let record = try self.storage.save(self.profile, id: self.currentId, addressMode: self.addressMode)
        self.currentId = record.id; self.profile = record.profile; self.source = source; self.stage = "done"
        if self.addressMode == .remote || record.remote != nil || record.profile.isShadowrocket { do { try await self.publish(record.id) } catch { self.error = "配置已保存，远程发布失败。请点击“重试发布”，无需重新配置。" } }
    } }
    func showAddresses(_ record: SubscriptionRecord) {
        currentId = record.id; profile = record.profile; addressMode = record.preferredAddressMode; stage = "done"; error = ""; message = ""
    }
    func selectAddressMode(_ value: SubscriptionAddressMode) {
        guard !busy, !profile.isShadowrocket, value != addressMode else { return }
        if stage != "done" { addressMode = value; draft(); return }
        guard let id = currentId else { return }
        perform {
            try self.storage.addressMode(id, value: value)
            self.addressMode = value
            if value == .remote, self.current?.remote == nil { try await self.publish(id) }
        }
    }
    func list() { draft(); stage = "list"; if client == "shadowrocket" { client = "static" }; error = ""; message = "" }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); if NSPasteboard.general.setString(value, forType: .string) { message = "已复制" } else { error = "复制失败" } }
    func importClash(_ record: SubscriptionRecord, remote: Bool = false) {
        guard !remote || record.remote != nil else { return }
        let url = remote ? record.remote!.subscriptionUrl : record.localURL
        var parts = URLComponents(); parts.scheme = "clash"; parts.host = "install-config"; parts.queryItems = [.init(name: "url", value: url), .init(name: "name", value: record.profile.name)]
        guard let link = parts.url else { return }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "party.mihomo.app") ?? ["/Applications/Clash Party.app"].map({ URL(fileURLWithPath: $0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { error = "未找到 Clash Party，请复制订阅地址手动导入"; return }
        NSWorkspace.shared.open([link], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in if error != nil { Task { @MainActor in self.error = "无法打开 Clash Party，请手动导入" } } }
    }
    func addGroup() { var index = profile.groups.count + 1; while profile.groups.contains(where: { $0.name == "自定义组 \(index)" }) { index += 1 }; profile.groups.append(.init(name: "自定义组 \(index)", nodes: [])); selectedGroup = profile.groups.count - 1; draft() }
    func removeGroup() { guard profile.groups.indices.contains(selectedGroup) else { return }; let name = profile.groups.remove(at: selectedGroup).name; profile.rules.removeAll { $0.group == name }; selectedGroup = 0; draft() }
    func renameGroup(_ name: String) { guard profile.groups.indices.contains(selectedGroup) else { return }; let old = profile.groups[selectedGroup].name; profile.groups[selectedGroup].name = name; for i in profile.rules.indices where profile.rules[i].group == old { profile.rules[i].group = name }; draft() }
    func sourceChanged(_ text: String) { profile.sourceUrl = text; source = nil; for i in profile.groups.indices where profile.groups[i].fixedExit != nil && profile.groups[i].chain != nil && profile.groups[i].chain?.entry != SubscriptionCore.autoChainEntry { profile.groups[i].chain?.entry = "" }; draft() }
    func remove(_ id: String) { perform { try self.storage.remove(id); self.deleteId = nil } }
    func syncRemote() { guard let id = currentId else { return }; perform { try await self.publish(id); self.message = "远程订阅已同步" } }
    func stopRemote() { guard let id = currentId else { return }; perform {
        guard !self.syncing.contains(id), let remote = self.current?.remote else { throw SubscriptionFailure("正在同步，请稍后重试") }
        self.syncing.insert(id); defer { self.syncing.remove(id) }
        let origin = try SubscriptionNetwork.remoteOrigin(remote)
        _ = try await SubscriptionNetwork.remoteRequest(origin: origin, path: "/api/remote-subscriptions/\(remote.id)", method: "DELETE", key: remote.manageKey, body: nil)
        try self.storage.remote(id, value: nil); self.message = "远程订阅已停用"
    } }
    private func publish(_ id: String) async throws {
        let deadline = Date().addingTimeInterval(60)
        while syncing.contains(id) {
            guard Date() < deadline else { throw SubscriptionFailure("线路正在同步，请稍后重试") }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        guard let record = records.first(where: { $0.id == id }) else { throw SubscriptionFailure("该配置已删除") }
        syncing.insert(id); defer { syncing.remove(id); objectWillChange.send() }
        do {
            let profile = try storage.resolved(record.profile)
            try SubscriptionCore.validate(profile)
            var source: SubscriptionSource?
            if !profile.isShadowrocket { source = try await SubscriptionNetwork.fetch(profile.sourceUrl); _ = try SubscriptionCore.transform(source!.config, profile: profile) }
            let data = try JSONEncoder().encode(profile)
            let object = try JSONSerialization.jsonObject(with: data)
            var payload: [String: Any] = ["profile": object, "sourceYaml": try source.map { try Yams.dump(object: $0.config, width: -1) } ?? "", "sourceFetchedAt": source?.fetchedAt ?? ISO8601DateFormatter().string(from: Date())]
            if let userInfo = source?.userInfo { payload["userInfo"] = userInfo }
            let origin = try record.remote.map(SubscriptionNetwork.remoteOrigin) ?? SubscriptionNetwork.remoteOrigin
            if origin == SubscriptionNetwork.legacyOrigin && record.profile.groups.contains(where: { $0.fixedExit != nil }) { throw SubscriptionFailure("旧托管链接不支持固定出口，请先停用旧链接再发布") }
            let path = "/api/remote-subscriptions" + (record.remote.map { "/" + $0.id } ?? "")
            let answer = try await SubscriptionNetwork.remoteRequest(origin: origin, path: path, method: record.remote == nil ? "POST" : "PUT", key: record.remote?.manageKey, body: JSONSerialization.data(withJSONObject: payload))
            var remote: SubscriptionRemote
            if var existing = record.remote { existing.updatedAt = answer["updatedAt"] as? Double ?? Date().timeIntervalSince1970 * 1000; existing.lastError = nil; remote = existing }
            else { guard let rid = answer["id"] as? String, let manage = answer["manageKey"] as? String, let download = answer["downloadKey"] as? String, let path = answer["subscriptionPath"] as? String else { throw SubscriptionFailure("远程响应格式无效") }; remote = .init(id: rid, manageKey: manage, downloadKey: download, subscriptionUrl: origin + path, updatedAt: answer["updatedAt"] as? Double ?? 0) }
            if let latest = records.first(where: { $0.id == id }), try storage.resolved(latest.profile) != profile { remote.lastError = "配置已变更，等待同步；请重试同步关联线路。" }
            _ = try SubscriptionNetwork.remoteOrigin(remote)
            try storage.remote(id, value: remote)
        } catch {
            if var remote = record.remote { remote.lastError = "远程同步失败，请重试"; try? storage.remote(id, value: remote) }
            throw error
        }
    }
    func editStaticNode(_ node: StaticProxyNode? = nil, linkGroup: Int? = nil) {
        error = ""; message = ""; editingStaticNodeId = node?.id; staticNodeName = node?.name ?? ""; staticNodeURL = node?.url ?? ""; staticLinkGroup = linkGroup; revealStaticNodeURL = false; showStaticNodeEditor = true
    }
    func associateStaticNode(_ id: String, group: Int) {
        guard profile.groups.indices.contains(group) else { return }
        profile.groups[group].staticNodeId = id.isEmpty ? nil : id
        profile.groups[group].fixedExit = staticNodes.first(where: { $0.id == id })?.url ?? ""
        profile.groups[group].nodes = []; draft()
    }
    func saveStaticNode() { perform {
        let previousURL = self.staticNodes.first(where: { $0.id == self.editingStaticNodeId })?.url
        let node = try self.storage.saveStaticNode(id: self.editingStaticNodeId, name: self.staticNodeName, url: self.staticNodeURL)
        self.profile = try self.storage.resolved(self.profile)
        if let group = self.staticLinkGroup { self.associateStaticNode(node.id, group: group) }
        self.showStaticNodeEditor = false
        self.message = "静态IP节点已保存"
        if previousURL != node.url { await self.syncPublishedStaticNode(node.id) }
    } }
    func syncStaticNode(_ id: String) { perform { await self.syncPublishedStaticNode(id) } }
    private func syncPublishedStaticNode(_ id: String) async {
        let ids = records.filter { $0.remote != nil && $0.profile.groups.contains(where: { $0.staticNodeId == id }) }.map(\.id)
        guard !ids.isEmpty else { return }
        var failed = 0
        for record in ids { do { try await publish(record) } catch { failed += 1 } }
        message = failed == 0 ? "已同步 \(ids.count) 条关联远程线路，请在客户端刷新订阅。" : "节点已保存；\(failed) 条远程线路同步失败，可点击“同步关联线路”重试。"
    }
    func showClashOverride(_ node: StaticProxyNode) {
        guard server.ready else { error = "本机服务未运行：" + server.status; return }
        do { clashOverrideLink = server.overrideURL(id: node.id, key: try storage.overrideKey(node.id), name: "Claude 固定线路") }
        catch { self.error = error.localizedDescription }
    }
    // ponytail: Clash Party has no deep link for overrides (only install-config), so the sheet guides a paste import.
    func openClashParty() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "party.mihomo.app") else { error = "未找到 Clash Party"; return }
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }
    /// Reuse the Shadowrocket line bound to this node, otherwise create and publish one, then show its setup page.
    func oneClickShadowrocket(_ node: StaticProxyNode) { perform {
        var record = self.shadowrocketRecord(for: node)
        if record == nil {
            var profile = SubscriptionProfile.mobile
            profile.name = String(("Claude 手机线路 · " + node.name).prefix(100))
            profile.groups[0].staticNodeId = node.id; profile.groups[0].fixedExit = node.url
            record = try self.storage.save(profile, id: nil)
        }
        guard let id = record?.id else { return }
        if self.records.first(where: { $0.id == id })?.remote == nil { try await self.publish(id) }
        guard let saved = self.records.first(where: { $0.id == id }) else { return }
        self.client = "shadowrocket"; self.showAddresses(saved)
    } }
    func removeStaticNode(_ id: String) { perform { try self.storage.removeStaticNode(id); self.deletingStaticNodeId = nil; self.message = "静态IP节点已删除" } }
    func setLogin(_ enabled: Bool) { login.setEnabled(enabled); let result = login.state(action: "state"); loginEnabled = result["enabled"] as? Bool ?? false; loginMessage = result["error"] as? String ?? ""; if !loginMessage.isEmpty { error = loginMessage } }
    func refreshLogin() { let result = login.state(action: "state"); loginEnabled = result["enabled"] as? Bool ?? false; loginMessage = result["error"] as? String ?? "" }
    func openLoginSettings() { login.openSettings() }
    static func isUS(_ name: String) -> Bool { name.contains("🇺🇸") || name.contains("美国") || name.range(of: "(^|[^a-z])(us|usa|united states)([^a-z]|$)", options: [.regularExpression, .caseInsensitive]) != nil }
    func measure(_ names: [String]) {
        guard !measuring, let source else { return }; measuring = true
        let group = profile.groups.indices.contains(selectedGroup) ? profile.groups[selectedGroup] : nil
        Task {
            let entry = group?.fixedExit == nil ? group?.chain?.entry : nil
            await withTaskGroup(of: (String, String).self) { tasks in
                var remaining = names.makeIterator()
                for _ in 0..<min(4, names.count) {
                    if let name = remaining.next() { tasks.addTask { (name, await SubscriptionDelay.measure(source: source, name: name, entry: entry)) } }
                }
                for await (name, result) in tasks {
                    delays[name] = result
                    if let next = remaining.next() { tasks.addTask { (next, await SubscriptionDelay.measure(source: source, name: next, entry: entry)) } }
                }
            }
            measuring = false
        }
    }
}
