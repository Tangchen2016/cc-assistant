import Foundation
import SwiftUI
import CryptoKit

struct AccountBrowserOverride: Codable, Equatable {
    var profileID = UUID()
    var proxy: String? = nil
    var timeZone: String? = nil
    var useSystemTimeZone = false
}

@MainActor final class AccountBrowserLibrary: ObservableObject {
    let defaults: RegistrationModel
    @Published private(set) var active: RegistrationModel
    @Published private(set) var activeEmail = ""
    @Published private(set) var entries: [String: AccountBrowserOverride] = [:]
    @Published private(set) var error = ""
    private let directory: URL
    private var models: [String: RegistrationModel] = [:]
    init(defaults: RegistrationModel, directory: URL? = nil) {
        self.defaults = defaults; active = defaults
        self.directory = directory ?? defaults.directory.appendingPathComponent("account-environments")
        let file = self.directory.appendingPathComponent("environments.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                guard data.count < 1024 * 1024 else { throw SubscriptionFailure("环境配置过大") }
                let loaded = try JSONDecoder().decode([String: AccountBrowserOverride].self, from: data)
                for (email, value) in loaded { _ = try AccountPoolStore.email(email); try validate(value) }
                entries = loaded
            } catch { self.error = "账号环境配置无法读取，已停止写入；请恢复配置文件。" }
        }
    }
    private func validate(_ value: AccountBrowserOverride) throws {
        if let proxy = value.proxy { _ = try RegistrationModel.proxyArgument(proxy) }
        if let zone = value.timeZone { _ = try RegistrationModel.validatedTimeZone(zone) }
    }
    func save(_ value: AccountBrowserOverride, email: String) throws {
        guard error.isEmpty else { throw SubscriptionFailure(error) }
        let email = try AccountPoolStore.email(email); try validate(value)
        var next = entries; next[email] = value
        try SubscriptionStorage.privateWrite(JSONEncoder().encode(next), to: directory.appendingPathComponent("environments.json"))
        entries = next
        if activeEmail == email { try select(email) }
    }
    func effective(_ value: AccountBrowserOverride) -> RegistrationSettings {
        var settings = defaults.settings
        settings.browserID = value.profileID
        settings.proxy = value.proxy ?? defaults.settings.proxy
        settings.timeZone = value.useSystemTimeZone ? nil : (value.timeZone ?? defaults.settings.timeZone)
        return settings
    }
    func model(for rawEmail: String, preferredProfileID: UUID? = nil) throws -> RegistrationModel {
        guard error.isEmpty else { throw SubscriptionFailure(error) }
        let email = try AccountPoolStore.email(rawEmail)
        // Preserve legacy associations. New accounts always get a separate data directory.
        if entries[email] == nil, preferredProfileID == defaults.settings.browserID { defaults.accountLabel = email; return defaults }
        var entry = entries[email] ?? AccountBrowserOverride()
        if entries[email] == nil {
            if let preferredProfileID { entry.profileID = preferredProfileID }
            try save(entry, email: email)
        }
        if let preferredProfileID, preferredProfileID != entry.profileID { throw SubscriptionFailure("此账号的浏览器环境关联已改变，请重新接入。") }
        let model: RegistrationModel
        if let cached = models[email] { model = cached }
        else {
            let key = SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
            model = RegistrationModel(directory: directory.appendingPathComponent(key)); models[email] = model
        }
        model.settings = effective(entry); model.accountLabel = email
        return model
    }
    /// The browser bound to this account: the profile its connection was made with, else its own environment.
    func browser(for row: AccountPoolRecord, connections: AccountConnectionStore) throws -> RegistrationModel {
        let profile = (try? connections.load(row.id))?.profileID
        return try model(for: row.email, preferredProfileID: profile)
    }
    /// Display-only: the settings this account's browser would use, without creating or saving anything.
    func preview(for row: AccountPoolRecord, connections: AccountConnectionStore) -> (settings: RegistrationSettings, model: RegistrationModel?)? {
        guard error.isEmpty, let email = try? AccountPoolStore.email(row.email) else { return nil }
        let profile = (try? connections.load(row.id))?.profileID
        if entries[email] == nil, profile == defaults.settings.browserID { return (defaults.settings, defaults) }
        guard let entry = entries[email] else { return nil }
        // Entry exists, so model(for:) only loads (no save); needed to see browsers opened before an app restart.
        let model = models[email] ?? (try? self.model(for: email, preferredProfileID: profile))
        return (effective(entry), model)
    }
    func select(_ email: String) throws {
        if email.isEmpty { active = defaults; activeEmail = ""; return }
        let selected = try model(for: email)
        active = selected; activeEmail = try AccountPoolStore.email(email)
    }
}

struct AccountBrowserPage: View {
    @ObservedObject var library: AccountBrowserLibrary
    @ObservedObject var accounts: AccountPoolModel
    @State private var email = ""
    @State private var draft = AccountBrowserOverride()
    @State private var message = ""
    init(library: AccountBrowserLibrary, accounts: AccountPoolModel) {
        self.library = library; self.accounts = accounts
        _email = State(initialValue: library.activeEmail)
        _draft = State(initialValue: library.entries[library.activeEmail] ?? .init())
    }
    var body: some View {
        Form {
            if email.isEmpty { BrowserSettingsPage(model: library.defaults) }
            else {
                Section {
                    Toggle("单独设置代理", isOn: Binding(get: { draft.proxy != nil }, set: { draft.proxy = $0 ? library.defaults.settings.proxy : nil }))
                    if draft.proxy != nil { TextField("代理地址", text: Binding(get: { draft.proxy ?? "" }, set: { draft.proxy = $0 }), prompt: Text("http://127.0.0.1:7890")) }
                    Picker("时区", selection: Binding(get: { draft.useSystemTimeZone ? "system" : draft.timeZone == nil ? "inherit" : "custom" }, set: { mode in draft.useSystemTimeZone = mode == "system"; draft.timeZone = mode == "custom" ? (library.defaults.settings.timeZone ?? "America/Los_Angeles") : nil })) {
                        Text("继承默认配置").tag("inherit")
                        Text("跟随系统").tag("system")
                        Text("指定时区").tag("custom")
                    }
                    if draft.timeZone != nil { TextField("指定时区", text: Binding(get: { draft.timeZone ?? "" }, set: { draft.timeZone = $0 }), prompt: Text("America/Los_Angeles")) }
                } header: { Text(email) } footer: {
                    HStack {
                        Text(message.isEmpty ? "未单独设置的项目继承默认配置。" : message)
                        Spacer()
                        Button("保存") {
                            do { try library.save(draft, email: email); message = "已保存。若浏览器运行中，请关闭重开以应用修改。" }
                            catch { message = error.localizedDescription }
                        }
                    }
                }
                Section("当前生效") {
                    LabeledContent("代理", value: library.active.settings.proxy.isEmpty ? "直连" : library.active.settings.proxy)
                    LabeledContent("时区", value: library.active.settings.timeZone ?? "跟随系统")
                    HStack {
                        Button("打开并检测") { library.active.openBrowser(RegistrationModel.browserCheckPage) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                        Button("打开 Claude") { library.active.openBrowser("https://claude.ai/", accountLink: true) }
                        Spacer()
                        Button("关闭浏览器") { library.active.closeBrowser() }
                    }
                    AccountEnvironmentStatus(model: library.active)
                }
            }
        }.formStyle(.grouped)
            .navigationTitle("浏览器")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("配置对象", selection: $email) {
                        Text("默认配置").tag("")
                        ForEach(Array(Set(accounts.activeRecords.map(\.email) + library.entries.keys)).sorted(), id: \.self) { Text($0).tag($0) }
                    }.help("选择要配置的账号浏览器环境")
                }
            }
            .onChange(of: email) { _, value in
            do { try library.select(value); draft = library.entries[value] ?? .init(); message = "" }
            catch { message = error.localizedDescription }
        }
    }
}
private struct AccountEnvironmentStatus: View {
    @ObservedObject var model: RegistrationModel
    var body: some View { Text(model.status).font(.footnote).foregroundStyle(.secondary) }
}

struct AccountBrowserConnectionHost: View {
    @ObservedObject var library: AccountBrowserLibrary
    @ObservedObject var model: AccountPoolModel
    var body: some View {
        AccountConnectionView(model: model, browser: library.active, browserResolver: { email in
            try library.select(email); return library.active
        }, browserContextEmail: library.activeEmail)
    }
}
