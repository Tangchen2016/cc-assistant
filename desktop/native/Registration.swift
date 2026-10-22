import Cocoa
import SwiftUI

struct RegistrationSettings: Codable {
    var browserID = UUID()
    var domain = ""
    var destination = ""
    var alias = "claude"
    var timeZone: String? = nil
    var proxy = "http://127.0.0.1:7890"
}

@MainActor final class RegistrationModel: ObservableObject {
    @Published private(set) var browserRuntime = BrowserRuntimeState()
    @Published private(set) var openingBrowser = false
    private var browserLaunchFailed = false
    @Published var settings = RegistrationSettings() {
        didSet {
            if settings.proxy != oldValue.proxy || settings.browserID != oldValue.browserID {
                exitTimeZone = nil; exitTimeZoneMessage = "代理或环境已改变，请刷新出口时区。"
                exitTimeZoneCheckedAt = nil; exitTimeZoneRequest = UUID(); checkingExitTimeZone = false
            }
            if settings.proxy != oldValue.proxy || settings.timeZone != oldValue.timeZone || settings.browserID != oldValue.browserID { refreshBrowserState() }
        }
    }
    @Published private(set) var exitTimeZone: BrowserExitTimeZone?
    @Published private(set) var checkingExitTimeZone = false
    @Published private(set) var exitTimeZoneMessage = ""
    private var exitTimeZoneCheckedAt: Date?
    private var exitTimeZoneRequest = UUID()
    @Published var status = ""
    @Published var checkingDNS = false
    @Published var dnsSummary = "尚未检查域名 DNS"
    private var loadFailed = false
    private let chrome = ManagedChrome()
    /// Account this environment belongs to; shown inside the browser. nil for the shared default environment.
    var accountLabel: String?
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("cc助手/registration", isDirectory: true)
        let file = self.directory.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { let data = try Data(contentsOf: file); guard data.count < 65536 else { throw CocoaError(.fileReadCorruptFile) }; settings = try JSONDecoder().decode(RegistrationSettings.self, from: data) }
            catch { loadFailed = true; status = "注册环境读取失败，请先恢复原有资料文件。" }
        }
    }
    func refreshExitTimeZone(force: Bool = false, resolve: @escaping @Sendable (PureBrowserConfiguration) async throws -> BrowserExitTimeZone = { try await BrowserExitTimeZoneLookup.resolve(configuration: $0) }) async {
        guard !checkingExitTimeZone, force || (exitTimeZoneCheckedAt.map({ Date().timeIntervalSince($0) >= 120 }) ?? true) else { return }
        let request = UUID(); exitTimeZoneRequest = request
        checkingExitTimeZone = true; exitTimeZone = nil; exitTimeZoneMessage = "正在读取浏览器的 Claude 出口及对应时区…"
        defer { if exitTimeZoneRequest == request { checkingExitTimeZone = false } }
        do {
            let configuration = try browserConfiguration()
            let value = try await resolve(configuration)
            guard exitTimeZoneRequest == request, !Task.isCancelled else { return }
            exitTimeZone = value; exitTimeZoneCheckedAt = Date(); exitTimeZoneMessage = ""
        } catch {
            guard exitTimeZoneRequest == request else { return }
            exitTimeZoneMessage = Task.isCancelled ? "查询已取消，可刷新出口时区。" : error.localizedDescription
        }
    }
    var address: String { settings.domain.isEmpty ? "填写域名后生成邮箱地址" : "\(settings.alias)@\(settings.domain)" }
    static func domainValid(_ value: String) -> Bool {
        value.count <= 253 && value.range(of: #"^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$"#, options: .regularExpression) != nil && ![".local", ".internal", ".localhost"].contains(where: value.lowercased().hasSuffix)
    }
    static func proxyArgument(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https", "socks5"].contains(scheme), let host = url.host, !host.isEmpty, let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, ["", "/"].contains(url.path), !value.contains(where: { $0.isWhitespace }) else { throw NSError(domain: "Registration", code: 1, userInfo: [NSLocalizedDescriptionKey: "请填写 HTTP / HTTPS / SOCKS5 代理主机和端口；带密码的代理可经本机代理转发。"] ) }
        return value
    }
    static func validatedTimeZone(_ value: String?) throws -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        guard value == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(value) else {
            throw NSError(domain: "Registration", code: 4, userInfo: [NSLocalizedDescriptionKey: "请选择有效的 IANA 时区，例如 America/Los_Angeles。"])
        }
        return value
    }
    @discardableResult func save() -> Bool {
        guard !loadFailed else { status = "原有注册环境文件无法读取，已拒绝覆盖。"; return false }
        do {
            settings.timeZone = try Self.validatedTimeZone(settings.timeZone)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(settings)
            guard data.count < 65536 else { throw CocoaError(.fileWriteUnknown) }
            let temporary = directory.appendingPathComponent("settings-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let target = directory.appendingPathComponent("settings.json")
            if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) } else { try FileManager.default.moveItem(at: temporary, to: target) }
            status = "已保存本机设置。"
            return true
        } catch { status = "保存失败，请检查本机目录权限。"; return false }
    }
    struct ProfileFolder: Identifiable, Equatable { let id: UUID; let created: Date?; let bytes: Int64; let hasLogin: Bool }
    /// Every profile folder ever created for this environment; old ones are kept, never deleted.
    nonisolated static func profileFolders(in directory: URL) -> [ProfileFolder] {
        let root = directory.appendingPathComponent("chrome-profiles", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return items.compactMap { url -> ProfileFolder? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            var bytes: Int64 = 0
            if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey]) {
                for case let file as URL in walker { bytes += Int64((try? file.resourceValues(forKeys: [.fileAllocatedSizeKey]))?.fileAllocatedSize ?? 0) }
            }
            return ProfileFolder(id: id, created: created, bytes: bytes, hasLogin: FileManager.default.fileExists(atPath: url.appendingPathComponent("Default/Cookies").path))
        }.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }
    /// Switches back to an existing profile folder (keeps its login state).
    func useProfile(_ id: UUID) {
        guard browserRuntime.pid == nil else { status = "请先关闭独立浏览器，再切换资料目录。"; return }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("chrome-profiles/\(id.uuidString)").path) else { status = "资料目录不存在。"; return }
        settings.browserID = id; status = "已切换到资料目录 \(id.uuidString.prefix(8))，登录资料保留。"; save()
    }
    func newBrowserEnvironment() { settings.browserID = UUID(); status = "已新建浏览器环境，原有资料目录保留。"; save() }
    func newAlias() { settings.alias = "claude-" + UUID().uuidString.prefix(8).lowercased() }
    var engine: URL? { ManagedChrome.executable }
    var engineName: String { engine == nil ? "未安装 Chrome" : engine?.lastPathComponent == "Chromium" ? "Chromium（cc助手管理）" : "Chrome（cc助手管理）" }
    var browserProfile: URL { directory.appendingPathComponent("chrome-profiles/\(settings.browserID.uuidString)", isDirectory: true) }
    func refreshBrowserState() {
        guard !openingBrowser else { return }
        guard let engine else { browserRuntime = .init(); return }
        let configuration = PureBrowserConfiguration(executable: engine, name: engineName, proxy: settings.proxy, timeZone: settings.timeZone)
        var state = chrome.runtime(profile: browserProfile, configuration: configuration)
        if state.phase == .failed { browserLaunchFailed = true }
        if state.pid != nil { browserLaunchFailed = false }
        if state.phase == .stopped && browserLaunchFailed { state.phase = .failed }
        browserRuntime = state
    }
    /// Brings this environment's running Chrome to the front. Chrome keeps running after its last window is closed,
    /// so with no visible window it opens claude.ai in the running instance instead (no new process, no exit re-check).
    func showBrowser() {
        refreshBrowserState()
        guard let pid = browserRuntime.pid, let app = NSRunningApplication(processIdentifier: pid) else {
            status = "未找到此环境的浏览器进程，请重新打开。"; return
        }
        guard Self.hasVisibleWindow(pid: pid) else { openBrowser("https://claude.ai/", checkExit: false); return }
        app.unhide()
        NSApp.yieldActivation(to: app)  // macOS 14 cooperative activation: the active app must hand over focus
        if !app.activate() { status = "系统未允许切换到浏览器，请在 Dock 中点它。" }
    }
    /// A normal on-screen window; Chrome's background helper windows are tiny, minimized ones are off-screen.
    nonisolated static func hasVisibleWindow(pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            (window[kCGWindowOwnerPID as String] as? pid_t) == pid && (window[kCGWindowLayer as String] as? Int) == 0
                && ((window[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 100
        }
    }
    func closeBrowser() {
        browserLaunchFailed = false
        status = chrome.close(profile: browserProfile) ? "正在关闭此独立浏览器，登录资料保留。" : "未找到属于此环境的运行进程，未关闭其他 Chrome。"
        refreshBrowserState()
    }
    func reconnectAccountBrowser() async {
        guard !openingBrowser else { return }
        let profile = browserProfile
        closeBrowser()
        for _ in 0..<50 {
            refreshBrowserState()
            guard browserProfile == profile else { status = "环境已改变，请重新打开官网。"; return }
            if browserRuntime.pid == nil {
                openBrowser("https://claude.ai/", accountLink: true)
                return
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
        }
        status = "浏览器尚未退出，请保存页面内容并手动关闭后，再点击打开官网。"
    }
    func browserConfiguration() throws -> PureBrowserConfiguration {
        guard !loadFailed else { throw NSError(domain: "Registration", code: 2, userInfo: [NSLocalizedDescriptionKey: "纯净浏览器配置无法读取，请到浏览器菜单检查设置。"]) }
        guard let engine else { throw NSError(domain: "Registration", code: 3, userInfo: [NSLocalizedDescriptionKey: "未安装纯净浏览器引擎，请先安装 Google Chrome。"]) }
        return PureBrowserConfiguration(executable: engine, name: engineName, proxy: try Self.proxyArgument(settings.proxy), timeZone: try Self.validatedTimeZone(settings.timeZone))
    }
    static let browserCheckPage = "https://tangchen02.top/apps/cc-assistant/check/?autostart=1"
    /// Check page that continues to claude.ai only after the exit check passes.
    static let browserCheckThenClaudePage = browserCheckPage + "&then=claude"
    /// Opening claude.ai always goes through the exit check first, including into an already-running browser
    /// (its window may have been launched before a line change). ponytail: re-checks each time; cache per launch if the wait bothers anyone.
    static func launchPage(for page: String) -> String { page == "https://claude.ai/" ? browserCheckThenClaudePage : page }
    func arguments(for page: String) throws -> [String] {
        guard [Self.browserCheckPage, Self.browserCheckThenClaudePage, "about:blank", "https://api.anthropic.com/cdn-cgi/trace", "https://claude.ai/", "https://claude.ai/settings/billing"].contains(page) || ClaudeMailLink.validated(page) != nil || LocalMailPage.permits(page) else { throw CocoaError(.validationMissingMandatoryProperty) }
        let proxy = try Self.proxyArgument(settings.proxy)
        let profile = browserProfile
        return PureBrowserConfiguration(executable: engine ?? URL(fileURLWithPath: "/"), name: engineName, proxy: proxy, timeZone: try Self.validatedTimeZone(settings.timeZone)).arguments(profile: profile) + ["--new-window", page]
    }
    func openBrowser(_ page: String, accountLink: Bool = false, checkExit: Bool = true) {
        guard !openingBrowser else { return }
        let page = checkExit ? Self.launchPage(for: page) : page
        do {
            _ = try arguments(for: page)
            let configuration = try browserConfiguration(), profile = browserProfile
            guard save() else { return }
            guard let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { throw SubscriptionFailure("cc助手图标资源缺失，请重新安装 App。") }
            openingBrowser = true; browserLaunchFailed = false; browserRuntime = .init(phase: .starting)
            status = "正在准备独立浏览器图标，首次打开可能需要几秒…"
            Task {
                defer { openingBrowser = false; refreshBrowserState() }
                do {
                    let executable = try await Task.detached(priority: .userInitiated) { try ChromeBrowserIdentity.prepare(source: configuration.executable, profile: profile, icon: icon) }.value
                    guard browserProfile == profile, settings.proxy == configuration.proxy, settings.timeZone == configuration.timeZone else {
                        status = "准备期间设置已改变，请重新打开浏览器。"; return
                    }
                    try chrome.open(configuration: configuration, profile: profile, page: page, launchExecutable: executable, accountLink: accountLink, label: accountLabel.map { "cc · \($0)" }, account: accountLabel)
                    status = page == Self.browserCheckPage ? "已在独立 Chrome 打开检测网页，将自动检测出口 IP 和浏览器时区。" : "已打开独立 Chrome，沿用此环境的登录资料。"
                } catch { browserLaunchFailed = true; status = error.localizedDescription }
            }
        } catch { browserLaunchFailed = true; status = error.localizedDescription; refreshBrowserState() }
    }
    func readLinkedAccount() async throws -> AccountIdentitySnapshot {
        let configuration = try browserConfiguration(), profile = browserProfile
        let allowed = [configuration.executable, ChromeBrowserIdentity.executable(profile: profile, source: configuration.executable)]
        guard let identity = BrowserProcessIdentity.read(profile: profile, allowedExecutables: allowed),
              let record = BrowserLaunchRecord.read(profile: profile, identity: identity),
              identity.proxy == configuration.proxy, record.timeZone == configuration.timeZone,
              identity.arguments.contains("--remote-debugging-port=0"),
              identity.arguments.contains("--remote-debugging-address=127.0.0.1") else {
            throw AccountConnectionError.browser("请先关闭此独立浏览器，再通过本页的“打开官网”重新打开以启用本机连接。")
        }
        let result = try await BrowserAccountReader.read(profile: profile)
        guard browserProfile == profile, BrowserProcessIdentity.read(profile: profile, allowedExecutables: allowed)?.sessionID == identity.sessionID else {
            throw AccountConnectionError.changed
        }
        return result
    }
    func checkDNS() async {
        guard Self.domainValid(settings.domain) else { dnsSummary = "请输入有效的公共域名，不带 https:// 或路径。"; return }
        let domain = settings.domain; checkingDNS = true
        defer { checkingDNS = false }
        do {
            var components = URLComponents(string: "https://cloudflare-dns.com/dns-query")!
            components.queryItems = [URLQueryItem(name: "name", value: domain), URLQueryItem(name: "type", value: "MX")]
            var request = URLRequest(url: components.url!); request.setValue("application/dns-json", forHTTPHeaderField: "Accept"); request.timeoutInterval = 12
            let configuration = URLSessionConfiguration.ephemeral; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 65536 else { throw CocoaError(.fileReadUnknown) }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let answers = json?["Answer"] as? [[String: Any]] ?? []
            let matches = answers.filter { ($0["type"] as? Int) == 15 }.compactMap { $0["data"] as? String }
            guard domain == settings.domain else { return }
            dnsSummary = matches.contains(where: { $0.lowercased().hasSuffix(".mx.cloudflare.net.") }) ? "检测到 Cloudflare MX。目标邮箱验证与 Catch-all 规则请在控制台确认。" : "未检测到 Cloudflare MX；请先完成域名接入和 Email Routing 设置。"
        } catch { dnsSummary = "DNS 检查失败，请稍后重试。" }
    }
}

struct LifecyclePage: View {
    let heading: String
    let subtitle: String
    let items: [(String, String, String, () -> Void)]
    var compact = false
    var body: some View {
        if compact { ScrollView { rows.padding(.horizontal, 32).padding(.vertical, 20).frame(maxWidth: Theme.contentWidth, alignment: .leading).frame(maxWidth: .infinity) } }
        else { Page(title: heading, subtitle: subtitle) { rows } }
    }
    private var rows: some View {
        VStack(alignment: .leading, spacing: 12) {
            if compact { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(action: item.3) { HStack(spacing: 14) {
                    Image(systemName: item.0).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.accent)
                        .frame(width: 38, height: 38).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) { Text(item.1).font(.system(size: 14, weight: .semibold)); Text(item.2).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer(); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                }.card(padding: 16).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
        }
    }
}

struct RegistrationPage: View {
    @ObservedObject var model: RegistrationModel
    let section: String
    var body: some View {
        Group {
            if section == "browser" { Form { BrowserSettingsPage(model: model) }.formStyle(.grouped).navigationTitle("浏览器设置") }
            else { registrationForm }
        }.task(id: section) { if section == "browser" { await model.refreshExitTimeZone() } }
    }
    private var registrationForm: some View {
        Page(title: section == "domain" ? "域名准备" : "域名邮箱配置", subtitle: section == "domain" ? "购买或复用自有域名，再接入 Cloudflare。" : "Catch-all 将未单独配置的邮箱前缀转发到已验证的目标邮箱。") {
            VStack(alignment: .leading, spacing: 16) {
                if section == "domain" {
                    field("自有域名", text: $model.settings.domain, placeholder: "example.com")
                    HStack { Button("前往 NameSilo") { NSWorkspace.shared.open(URL(string: "https://www.namesilo.com/")!) }; Button("打开 Cloudflare 控制台") { NSWorkspace.shared.open(URL(string: "https://dash.cloudflare.com/")!) } }
                    Text("在域名服务商完成购买，并按 Cloudflare 提示修改权威 DNS。已有域名可以直接复用。").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if section == "email" {
                    field("域名", text: $model.settings.domain, placeholder: "example.com")
                    field("转发目标邮箱", text: $model.settings.destination, placeholder: "your-inbox@example.com")
                    field("注册邮箱前缀", text: $model.settings.alias, placeholder: "claude")
                    HStack { Text(model.address).font(.system(size: 13, design: .monospaced)); Spacer(); Button("生成新前缀") { model.newAlias() } }
                    Text("设置顺序：启用 Email Routing → 验证目标邮箱 → 配置 *@域名 的 Catch-all 转发 → 从外部邮箱测试收信。").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack { Button(model.checkingDNS ? "检查中…" : "检查域名 MX") { Task { await model.checkDNS() } }.disabled(model.checkingDNS); Button("打开 Cloudflare 设置") { NSWorkspace.shared.open(URL(string: "https://dash.cloudflare.com/")!) } }
                    Text(model.dnsSummary).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("当前仅检查 DNS；未将本地填写的资料标记为 Cloudflare 转发已生效。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if section != "browser" { Divider(); HStack { Spacer(); Button("保存注册环境") { model.save() }.buttonStyle(.borderedProminent).tint(Theme.accent) } }
            }.card(padding: 24)
            if !model.status.isEmpty { Text(model.status).font(.system(size: 12)).foregroundStyle(.secondary) }
        }

    }
    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 12)).foregroundStyle(.secondary); TextField(placeholder, text: text).textFieldStyle(.roundedBorder) }
    }
}
