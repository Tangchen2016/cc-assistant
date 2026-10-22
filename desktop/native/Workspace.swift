import Cocoa
import SwiftUI
import Combine
import Network

/// Navigation state and the cross-model wiring the pages share.
@MainActor final class WorkspaceModel: ObservableObject {
    enum Route: String, CaseIterable, Identifiable {
        case overview, lines, detection, requests, browser, accounts, guide
        var id: String { rawValue }
        var title: String { ["overview": "概览", "lines": "线路", "detection": "检测", "requests": "请求", "browser": "浏览器", "accounts": "号池", "guide": "指南"][rawValue]! }
        var symbol: String { ["overview": "gauge.with.dots.needle.33percent", "lines": "arrow.triangle.branch", "detection": "checkmark.shield", "requests": "list.bullet.rectangle", "browser": "macwindow", "accounts": "person.2.crop.square.stack", "guide": "book.closed"][rawValue]! }
    }
    @Published var route: Route = .overview { didSet { subpage = nil; UserDefaults.standard.set(route.rawValue, forKey: "selectedMenu") } }
    /// A guide step opened in place of the guide ("domain" / "email").
    @Published var subpage: String?
    let subscriptions: SubscriptionModel
    let updates: AppUpdates
    let accounts: AccountPoolModel
    let egress = EgressCheckModel()
    let registration = RegistrationModel()
    let browsers: AccountBrowserLibrary
    let guideNavigation = AccountGuideNavigation()
    let clash = ClashObserver()
    var openSettings: () -> Void = {}
    private var monitor: Task<Void, Never>?
    private var checkWatch: AnyCancellable?
    private var checkLoop: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var routeWatch: AnyCancellable?
    private var pendingRecheck: Task<Void, Never>?
    private var proxySignature: String?

    /// Coalesces a burst of change signals into one silent check once the route has settled.
    func scheduleRecheck(_ reason: String) {
        pendingRecheck?.cancel()
        pendingRecheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // A check already in flight may predate the change, so wait for it rather than drop this one.
            while self?.egress.busy == true, !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard !Task.isCancelled, let self else { return }
            TrafficLog.append("EGRESS", "recheck \(reason)")
            self.egress.refreshSilently(hosts: EgressLocalDiagnostics.commonHosts)
        }
    }
    init(subscriptions: SubscriptionModel, updates: AppUpdates, accounts: AccountPoolModel) {
        self.subscriptions = subscriptions; self.updates = updates; self.accounts = accounts
        browsers = AccountBrowserLibrary(defaults: registration)
        subscriptions.markedIP = { [weak egress] in egress?.markedIP }
        clash.watchedDomains = { [weak subscriptions] in
            Array(Set(ClashObserver.claudeDomains + (subscriptions?.records.flatMap { $0.profile.rules.filter { $0.type != "DOMAIN-KEYWORD" }.map { $0.value.lowercased() } } ?? [])))
        }
        clash.start()
        // The exit check refreshes in the background on a schedule and on network change; while it runs the Clash
        // observer notes which nodes its probes used, then the single exit IP is mapped onto them.
        checkWatch = egress.$running.combineLatest(egress.$backgroundRunning).map { $0 || $1 }.removeDuplicates().dropFirst().filter { $0 }.sink { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let nodes = await self.clash.captureDuringCheck { [weak self] in self?.egress.busy ?? false }
                if self.egress.exitIPs.count == 1, let ip = self.egress.exitIPs.first {
                    self.clash.record(exit: ip, country: self.egress.successful.first?.country, nodes: nodes)
                }
                // The 16-domain route scan curls browser-facing hosts: only after a check the user started.
                if self.egress.lastRunManual { await self.clash.checkCoverage() }
            }
        }
        // Checks are change-driven: network path, system proxy settings, Clash route or Clash restart.
        // An hourly silent check is only the fallback for an upstream IP that rotates behind the same node.
        checkLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                let signature = (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as NSDictionary?)?.description
                if signature != self.proxySignature { if self.proxySignature != nil { self.scheduleRecheck("系统代理变化") }; self.proxySignature = signature }
                if Date().timeIntervalSince(self.egress.lastCheck ?? .distantFuture) >= 3600 { self.egress.refreshSilently(hosts: EgressLocalDiagnostics.commonHosts) }
            }
        }
        routeWatch = clash.$claudeRoute.compactMap { $0 }.removeDuplicates().dropFirst()
            .map { _ in "Clash 线路变化" }
            .merge(with: clash.$controller.map { $0 != nil }.removeDuplicates().drop(while: { !$0 }).dropFirst().map { _ in "Clash 重启" })
            .sink { [weak self] reason in self?.scheduleRecheck(reason) }
        let path = NWPathMonitor()
        var lastPath: String?
        path.pathUpdateHandler = { [weak self] update in
            // NWPathMonitor also fires for no-op updates; only a different interface/gateway set is a real change.
            let signature = "\(update.status)|" + update.availableInterfaces.map(\.name).joined(separator: ",") + "|" + update.gateways.map { "\($0)" }.sorted().joined(separator: ",")
            Task { @MainActor in
                defer { lastPath = signature }
                guard let previous = lastPath, previous != signature else { return }
                self?.scheduleRecheck("网络变化")
            }
        }
        path.start(queue: .global(qos: .utility)); pathMonitor = path
        accounts.connectionFlow.prepareBrowser = { [weak self] email in
            guard let self else { throw AccountConnectionError.noConnection }
            try self.browsers.select(email)
        }
        accounts.connectionFlow.openBrowser = { [weak self] connect in self?.browsers.active.openBrowser("https://claude.ai/", accountLink: connect) }
        accounts.readAccountBrowser = { [weak self] row, connection in
            guard let self else { throw AccountConnectionError.noConnection }
            return try await self.browsers.model(for: row.email, preferredProfileID: connection.profileID).readLinkedAccount()
        }
        accounts.accountSessionProxy = { [weak self] email in
            guard let self else { throw AccountConnectionError.noConnection }
            return try RegistrationModel.proxyArgument(self.browsers.model(for: email).settings.proxy)
        }
        accounts.connectionFlow.browserProfile = { [weak self] in self?.browsers.active.settings.browserID ?? UUID() }
        accounts.connectionFlow.browserReader = { [weak self] in
            guard let self else { throw AccountConnectionError.noConnection }
            return try await self.registration.readLinkedAccount()
        }
        accounts.connectionFlow.sessionProxyForEmail = accounts.accountSessionProxy
        accounts.connectionFlow.sessionProxy = { [weak self] in
            guard let self else { throw AccountConnectionError.noConnection }
            return try RegistrationModel.proxyArgument(self.browsers.active.settings.proxy)
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.browsers.active.refreshBrowserState()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
        open(UserDefaults.standard.string(forKey: "selectedMenu") ?? "overview")
    }
    deinit { monitor?.cancel(); checkLoop?.cancel(); pathMonitor?.cancel() }

    /// Accepts current routes and the keys older versions and guide links use.
    func open(_ key: String) {
        switch key {
        case "settings": openSettings()
        case "account-register":
            route = .accounts
            accounts.beginConnection(.register, email: (try? AccountPoolStore.email(registration.address)) ?? "")
        case "domain", "email": route = .guide; subpage = key
        case "lines", "enhancement", "chain": route = .lines
        case "detection", "environment": route = .detection
        case "guide", "registration", "payment", "usage":
            if let section = AccountGuideSection.forRoute(key) { guideNavigation.section = section }
            route = .guide
        default: route = Route(rawValue: key) ?? .overview
        }
    }
}

struct RootView: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.route }, set: { if let route = $0 { model.route = route } })) {
                row(.overview)
                Section("网络") { row(.lines); row(.detection); row(.requests); row(.browser) }
                Section("账号") { row(.accounts); row(.guide) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    UpdateSidebarView(updates: model.updates)
                    HStack {
                        Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Button { model.openSettings() } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.borderless).help("设置… (⌘,)").accessibilityLabel("设置")
                    }
                }.padding(12)
            }
        } detail: {
            detail.frame(minWidth: 640, minHeight: 520)
        }
    }

    @ViewBuilder private func row(_ route: WorkspaceModel.Route) -> some View {
        if route == .browser { BrowserRow(library: model.browsers).tag(route) }
        else { Label(route.title, systemImage: route.symbol).tag(route) }
    }

    @ViewBuilder private var detail: some View {
        switch model.route {
        case .overview: OverviewView(model: model, subscriptions: model.subscriptions, egress: model.egress, browsers: model.browsers, accounts: model.accounts)
        case .lines: SubscriptionView(model: model.subscriptions, server: model.subscriptions.server)
        case .detection: EgressDetectionView(model: model.egress, onEnhancement: { model.route = .lines }, clash: model.clash)
        case .requests:
            ConnectionsView(subscriptions: model.subscriptions, clash: model.clash, egress: model.egress)
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)).navigationTitle("请求")
        case .browser: AccountBrowserPage(library: model.browsers, accounts: model.accounts)
        case .accounts: AccountPoolView(model: model.accounts, browser: model.registration, browserLibrary: model.browsers, onBrowserSettings: { model.route = .browser })
        case .guide:
            if let section = model.subpage {
                RegistrationPage(model: model.registration, section: section)
                    .toolbar { ToolbarItem(placement: .navigation) { Button { model.subpage = nil } label: { Label("指南", systemImage: "chevron.backward") }.help("返回指南") } }
            } else {
                AccountGuideView(browser: model.registration, navigation: model.guideNavigation, onNavigate: model.open)
            }
        }
    }
}

/// Sidebar row that shows the managed browser's state as a badge.
private struct BrowserRow: View {
    @ObservedObject var library: AccountBrowserLibrary
    var body: some View { BrowserRowLabel(model: library.active) }
}
private struct BrowserRowLabel: View {
    @ObservedObject var model: RegistrationModel
    var body: some View {
        Label("浏览器", systemImage: "macwindow")
            .badge(model.browserRuntime.phase == .stopped ? nil : Text(model.browserRuntime.phase.rawValue))
            .help("独立浏览器：" + model.browserRuntime.phase.rawValue)
    }
}
