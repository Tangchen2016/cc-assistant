import Cocoa
import WebKit

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

@MainActor final class StudioDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private let port = 19473
    private var process: Process?
    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private var buffer = Data()
    private var startupTimer: Timer?
    private var ready = false
    private var quitting = false
    private var launchFailure = false
    private var quitTimer: Timer?
    private var quitRequest: String?
    private let loginItems = LoginItems()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let identifier = Bundle.main.bundleIdentifier ?? "local.subscription.studio"
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        loginItems.configureDefault()
        configureMenus()
        let controller = WKUserContentController()
        controller.add(self, name: "desktop")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "cc助手"
        window.minSize = NSSize(width: 1260, height: 640)
        window.contentView = WorkspaceView(webView: webView)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        webView.loadHTMLString("<html><body style='font:16px -apple-system;padding:60px;color:#14283e;background:#f5f7fa'><h1>cc助手</h1><p>正在启动本地订阅服务…</p></body></html>", baseURL: nil)
        showWindow()
        launchService()
    }

    private func configureMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示 cc助手", action: #selector(showWindow), keyEquivalent: "1")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 cc助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu; menu.addItem(editItem); NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "cc助手")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "显示 cc助手", action: #selector(showWindow), keyEquivalent: "")
        statusMenu.addItem(withTitle: "退出（本地订阅将停止更新）", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = statusMenu
    }

    private func launchService() {
        guard let resources = Bundle.main.resourceURL else { fail("应用资源缺失，请重新安装。"); return }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        let child = Process()
        child.executableURL = resources.appendingPathComponent("node-\(architecture)")
        child.arguments = [resources.appendingPathComponent("server.mjs").path]
        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = String(port)
        environment["DESKTOP_ASSETS_DIR"] = resources.appendingPathComponent("public").path
        environment["DESKTOP_DATA_DIR"] = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Subscription Studio").path
        environment["DESKTOP_MIHOMO_PATH"] = resources.appendingPathComponent("mihomo-\(architecture)").path
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_PATH")
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, !self.quitting, !self.launchFailure else { return }
                self.fail(child.terminationStatus == 0 ? "本地订阅服务已停止，请重新打开 App。" : "本地订阅服务启动失败或意外退出。请检查端口 19473 是否被占用，然后重新打开 App。")
            }
        }
        process = child
        do { try child.run() }
        catch { fail("无法启动应用内置的本地服务，请重新安装。"); return }
        startupTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in DispatchQueue.main.async { self?.fail("本地服务启动超时，请退出后重新打开 App。") } }
    }

    private func consume(_ data: Data) {
        guard !ready, !launchFailure else { return }
        buffer.append(data)
        guard buffer.count < 8192 else { fail("本地服务启动响应异常。"); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if message["ready"] as? Bool == true, message["port"] as? Int == port {
                ready = true; startupTimer?.invalidate()
                webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)); return
            }
            if message["error"] != nil { fail("本地服务无法启动。请检查端口 19473 是否已被占用。"); return }
        }
    }

    private func fail(_ reason: String) {
        guard !launchFailure else { return }
        launchFailure = true; startupTimer?.invalidate()
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        let alert = NSAlert(); alert.messageText = "cc助手无法继续运行"; alert.informativeText = reason
        alert.addButton(withTitle: "退出"); alert.runModal(); NSApp.terminate(nil)
    }

    @objc private func showWindow() {
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ready, !launchFailure else { return .terminateNow }
        let request = UUID().uuidString
        quitRequest = request
        quitTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in DispatchQueue.main.async { self?.confirmUnsavedQuit() } }
        webView.evaluateJavaScript("Promise.resolve().then(() => { if (typeof window.__flushSubscriptionDraft !== 'function') throw new Error('not ready'); return window.__flushSubscriptionDraft(); }).then(() => window.webkit.messageHandlers.desktop.postMessage({action:'quitReady',request:'\(request)',ok:true})).catch(() => window.webkit.messageHandlers.desktop.postMessage({action:'quitReady',request:'\(request)',ok:false}));", completionHandler: nil)
        return .terminateLater
    }
    private func confirmUnsavedQuit() {
        quitTimer?.invalidate(); quitTimer = nil; quitRequest = nil
        let alert = NSAlert(); alert.messageText = "最新修改尚未保存"; alert.informativeText = "本机保存未完成。继续退出可能丢失刚输入的订阅地址或规则。"
        alert.addButton(withTitle: "返回 App"); alert.addButton(withTitle: "仍然退出")
        NSApp.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
    }
    func applicationWillTerminate(_ notification: Notification) {
        quitting = true; startupTimer?.invalidate(); quitTimer?.invalidate(); process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate(); process?.waitUntilExit() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(url.scheme == "about" || url.scheme == "http" && url.host == "127.0.0.1" && url.port == port ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard ready, message.frameInfo.isMainFrame, origin.protocol == "http", origin.host == "127.0.0.1", origin.port == port,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        if action == "getLoginItem" { replyMessage(loginItems.state(action: action)); return }
        if action == "setLoginItem", let enabled = body["enabled"] as? Bool { loginItems.setEnabled(enabled); replyMessage(loginItems.state(action: action)); return }
        if action == "openLoginSettings" { loginItems.openSettings(); return }
        if action == "quitReady", quitTimer != nil, body["request"] as? String == quitRequest {
            quitTimer?.invalidate(); quitTimer = nil; quitRequest = nil
            if body["ok"] as? Bool == true { NSApp.reply(toApplicationShouldTerminate: true) }
            else { confirmUnsavedQuit() }
            return
        }
        if action == "copy", let text = body["text"] as? String, text.utf8.count <= 16384 {
            NSPasteboard.general.clearContents(); let ok = NSPasteboard.general.setString(text, forType: .string)
            reply(action, ok: ok, error: ok ? nil : "复制失败，请手动复制。"); return
        }
        guard action == "importClash", let raw = body["url"] as? String, raw.count <= 4096,
              let parts = URLComponents(string: raw), parts.scheme == "clash", parts.host == "install-config",
              let target = parts.queryItems?.first(where: { $0.name == "url" })?.value,
              let subscription = URL(string: target), validSubscription(subscription),
              subscription.user == nil, subscription.password == nil, subscription.query == nil, subscription.fragment == nil,
              let link = parts.url else { reply(action, ok: false, error: "导入地址无效，请重新保存配置。"); return }
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "party.mihomo.app") ?? ["/Applications/Clash Party.app", NSHomeDirectory() + "/Applications/Clash Party.app"].map { URL(fileURLWithPath: $0) }.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        guard let application = appURL else { reply(action, ok: false, error: "未找到 Clash Party，请先安装，或复制订阅地址手动导入。"); return }
        NSWorkspace.shared.open([link], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            DispatchQueue.main.async { self?.reply(action, ok: error == nil, error: error == nil ? nil : "无法打开 Clash Party，请复制地址手动导入。") }
        }
    }

    private func validSubscription(_ url: URL) -> Bool {
        let local = url.scheme == "http" && url.host == "127.0.0.1" && url.port == port
        let remote = url.scheme == "https" && url.host == "cc-assistant-api.tangchen19942016.workers.dev" && (url.port == nil || url.port == 443)
        let prefix = local ? "sub" : "remote-sub"
        return (local || remote) && url.path.range(of: "^/\(prefix)/[a-f0-9]{32}/[a-f0-9]{64}/[^/]+$", options: .regularExpression) != nil
    }

    private func reply(_ action: String, ok: Bool, error: String?) {
        replyMessage(["action": action, "ok": ok, "error": error ?? ""])
    }
    private func replyMessage(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('desktop-result', {detail: \(json)}));", completionHandler: nil)
    }
}
