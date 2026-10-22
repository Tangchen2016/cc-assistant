import SwiftUI
import AppKit

/// Settings window (⌘,): fixed toolbar tabs, dimmed minimize/zoom, restores the last pane.
@MainActor final class SettingsWindowController: NSWindowController {
    private final class Tabs: NSTabViewController {
        override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
            super.tabView(tabView, didSelect: tabViewItem)
            UserDefaults.standard.set(selectedTabViewItemIndex, forKey: "settingsPane")
        }
    }
    init(subscriptions: SubscriptionModel, updates: AppUpdates) {
        let tabs = Tabs()
        tabs.tabStyle = .toolbar
        let panes: [(String, String, AnyView)] = [
            ("通用", "gearshape", AnyView(GeneralSettingsView(subscriptions: subscriptions))),
            ("软件更新", "arrow.down.circle", AnyView(UpdateSettingsView(updates: updates))),
        ]
        for (title, symbol, view) in panes {
            let host = NSHostingController(rootView: view.frame(width: 520))
            host.sizingOptions = .preferredContentSize  // window follows each pane's height
            host.title = title  // propagated to the window title (HIG: title reflects the pane)
            let item = NSTabViewItem(viewController: host)
            item.label = title; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = min(max(UserDefaults.standard.integer(forKey: "settingsPane"), 0), panes.count - 1)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() { if window?.isVisible != true { window?.center() }; showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}

struct GeneralSettingsView: View {
    @ObservedObject var subscriptions: SubscriptionModel
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知" }
    var body: some View {
        Form {
            Section {
                Toggle("登录时启动 cc助手", isOn: Binding(get: { subscriptions.loginEnabled }, set: subscriptions.setLogin))
                Button("管理 macOS 登录项…", action: subscriptions.openLoginSettings)
                Toggle("在菜单栏显示 cc助手", isOn: $showMenuBarExtra)
                if !subscriptions.loginMessage.isEmpty { Text(subscriptions.loginMessage).foregroundStyle(.orange) }
            } footer: { Text("关闭主窗口后，cc助手继续在菜单栏运行；本机订阅服务随 App 退出而停止。") }
            Section {
                LabeledContent("版本", value: "\(version)（\(build)）")
                LabeledContent("数据") {
                    HStack {
                        Button("打开数据目录") { NSWorkspace.shared.open(subscriptions.storage.directory) }
                        Button("软件主页") { NSWorkspace.shared.open(URL(string: "https://tangchen02.top/apps/cc-assistant/")!) }
                    }
                }
            } footer: { Text("线路配置、访问密钥和浏览器资料保存在本机用户目录，升级保留已有资料。") }
        }.formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            .onAppear { subscriptions.refreshLogin() }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdates
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知" }
    var body: some View {
        Form {
            Section {
                LabeledContent("当前版本", value: version)
                LabeledContent("检查更新") {
                    HStack {
                        if updates.checking { ProgressView().controlSize(.small) }
                        Button(updates.checking ? "检查中…" : "立即检查", action: updates.checkNow).disabled(updates.checking || updates.running)
                    }
                }
                if !updates.version.isEmpty {
                    LabeledContent("新版本 v\(updates.version)") {
                        Button(updates.running ? updates.status : "更新并重启", action: updates.install).disabled(updates.running)
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                }
                if updates.running {
                    ProgressView(value: updates.progress)
                    if updates.canCancel { Button("取消下载", action: updates.cancel) }
                }
                if !updates.checkMessage.isEmpty { Text(updates.checkMessage).foregroundStyle(.secondary) }
                if !updates.failure.isEmpty { Text(updates.failure).foregroundStyle(.orange) }
            } footer: {
                if let checked = updates.lastCheckedAt { Text("最近检查：" + checked.formatted(date: .abbreviated, time: .shortened)) }
            }
            Section {
                Toggle("自动检查更新", isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticChecks))
            } footer: { Text("启动时及每小时检查一次；发现更新后等你确认，下载校验后自动重启并保留设置。") }
        }.formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
    }
}
