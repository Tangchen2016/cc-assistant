import Cocoa
import Sparkle
import SwiftUI
import Combine

@main
struct SubscriptionStudio {
    static func main() {
        let app = NSApplication.shared
        let delegate = StudioDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor final class StudioDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var workspace: WorkspaceModel?
    private var panel: MenuBarPanelController?
    private var observers: [AnyCancellable] = []
    private lazy var settings = SettingsWindowController(subscriptions: subscriptions, updates: updates)
    private let subscriptions = SubscriptionModel()
    private let accounts = AccountPoolModel()
    private let loginItems = LoginItems()
    private lazy var updates = AppUpdates { [weak self] in
        guard let self, !self.subscriptions.busy, !self.accounts.showEditor, !self.accounts.showConnection else { return false }
        self.subscriptions.draft()
        return !self.subscriptions.error.contains("草稿保存失败")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let identifier = Bundle.main.bundleIdentifier ?? "local.subscription.studio"
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { NSApp.applicationIconImage = NSImage(contentsOf: icon) }
        loginItems.configureDefault(); configureMenus()
        let workspace = WorkspaceModel(subscriptions: subscriptions, updates: updates, accounts: accounts)
        workspace.openSettings = { [weak self] in self?.showSettings() }
        self.workspace = workspace
        configureStatusItem(workspace)
        // SwiftUI split view; page titles and actions bridge into the native unified toolbar.
        let host = NSHostingController(rootView: RootView(model: workspace))
        host.sceneBridgingOptions = [.toolbars, .title]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = host
        window.toolbar = NSToolbar(identifier: "main")
        window.toolbarStyle = .unified
        window.title = "cc助手"; window.minSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.delegate = self; window.isReleasedWhenClosed = false; window.center()
        window.setFrameAutosaveName("MainWindow")
        HandCursor.install(); HandCursor.track(window)
        showWindow(); subscriptions.start(); updates.start()
        workspace.egress.check(hosts: EgressLocalDiagnostics.commonHosts, manual: false)
    }
    private func configureMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示 cc助手", action: #selector(showWindow), keyEquivalent: "1")
        let updateItem = appMenu.addItem(withTitle: "检查更新…", action: #selector(AppUpdates.checkManually), keyEquivalent: "")
        updateItem.target = updates
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 cc助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu; menu.addItem(editItem); NSApp.mainMenu = menu
    }

    /// Menu bar extra with a quick panel; people can hide it in Settings (HIG: their choice).
    private func configureStatusItem(_ workspace: WorkspaceModel) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.setAccessibilityLabel("cc助手")
        panel = MenuBarPanelController(content: MenuBarPanel(model: workspace, subscriptions: subscriptions, egress: workspace.egress, browsers: workspace.browsers, accounts: accounts, updates: updates,
            openWindow: { [weak self] route in self?.panel?.close(); if let route { workspace.route = route }; self?.showWindow() },
            openSettings: { [weak self] in self?.panel?.close(); self?.showSettings() }))
        observers = [
            // Filled shield while the built-in proxy runs; ring color = exit health.
            subscriptions.objectWillChange.merge(with: workspace.egress.objectWillChange).prepend(())
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    // While the proxy runs, its gate decides the color; otherwise the last exit check does.
                    let health: EgressHealth? = switch self.subscriptions.gate {
                    case .open: .ok
                    case .blocked: .failed
                    case .checking: .warning
                    case .idle: workspace.egress.health
                    }
                    self.statusItem.button?.image = StatusIcon.image(filled: self.subscriptions.lineRunning, health: health)
                },
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in self?.applyStatusItemVisibility() },
        ]
        applyStatusItemVisibility()
    }
    private func applyStatusItemVisibility() {
        let visible = UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true
        if statusItem.isVisible != visible { statusItem.isVisible = visible }
    }
    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if panel?.isShown == false { accounts.refreshStaleUsage() }
        panel?.toggle(below: button)
    }
    /// Same quick actions from the Dock icon, which is always available.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if LineEngine.enabled && subscriptions.lineRunning { menu.addItem(withTitle: "停止内置代理", action: #selector(dockStopLine), keyEquivalent: "") }
        menu.addItem(withTitle: "重新检测出口", action: #selector(dockCheck), keyEquivalent: "")
        menu.addItem(withTitle: "打开浏览器", action: #selector(dockOpenBrowser), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }
    @objc private func dockStopLine() { subscriptions.stopLine() }
    @objc private func dockCheck() { workspace?.egress.check() }
    @objc private func dockOpenBrowser() { workspace?.browsers.active.openBrowser(RegistrationModel.browserCheckPage) }


    @objc private func showSettings() { settings.show(); HandCursor.track(settings.window) }
    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if accounts.hasUnsavedChanges {
            let alert = NSAlert(); alert.messageText = "账号资料尚未保存"; alert.informativeText = "请返回保存，或放弃本次编辑后退出。"
            alert.addButton(withTitle: "返回编辑"); alert.addButton(withTitle: "放弃编辑并退出")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        subscriptions.draft()
        if subscriptions.error.contains("草稿保存失败") {
            let alert = NSAlert(); alert.messageText = "草稿尚未保存"; alert.informativeText = "继续退出可能丢失本次修改。"; alert.addButton(withTitle: "返回 App"); alert.addButton(withTitle: "仍然退出")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { subscriptions.stop(); SubscriptionDelay.stopAll(); LineEngine.stop() }
}
