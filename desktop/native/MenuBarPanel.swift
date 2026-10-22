import SwiftUI
import AppKit

/// Borderless panel that drops from the menu bar icon (no popover arrow), closes on outside click.
@MainActor final class MenuBarPanelController {
    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
    private let panel: NSPanel
    private var monitors: [Any] = []
    init<Content: View>(content: Content) {
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true; panel.level = .statusBar; panel.hasShadow = true
        panel.backgroundColor = .clear; panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: content.background(PanelMaterial()).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)))
        panel.contentView = host
        panel.acceptsMouseMovedEvents = true
    }
    var isShown: Bool { panel.isVisible }
    func toggle(below button: NSStatusBarButton) { isShown ? close() : show(below: button) }
    func show(below button: NSStatusBarButton) {
        guard let anchor = button.window?.convertToScreen(button.convert(button.bounds, to: nil)), let screen = button.window?.screen ?? NSScreen.main else { return }
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 380, height: 420))
        let size = panel.frame.size, visible = screen.visibleFrame
        // Left edge under the icon, 6pt below the menu bar, kept on screen.
        let x = min(max(anchor.minX - 8, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 6))
        panel.orderFrontRegardless(); panel.makeKey()
        let statusWindow = button.window
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in Task { @MainActor in self?.close() } },
            // Clicks in our other windows close it too; the status button toggles on its own.
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, event.window !== self.panel, event.window !== statusWindow { self.close() }
                return event
            },
        ].compactMap { $0 }
    }
    func close() {
        panel.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor); monitors = []
    }
}

private struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .popover; view.blendingMode = .behindWindow; view.state = .active; return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Menu bar quick panel: live status plus the few actions people repeat every day.
struct MenuBarPanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var subscriptions: SubscriptionModel
    @ObservedObject var egress: EgressCheckModel
    @ObservedObject var browsers: AccountBrowserLibrary
    @ObservedObject var accounts: AccountPoolModel
    @ObservedObject var updates: AppUpdates
    let openWindow: (WorkspaceModel.Route?) -> Void
    let openSettings: () -> Void
    @AppStorage("claudeLine.selectedRecord") private var lineID = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                stats
                egressFailures
                if !accounts.activeRecords.isEmpty { AccountUsageCard(accounts: accounts) { openWindow(.accounts) } }
                if LineEngine.enabled { lineCard }
                actions
            }.padding(14)
            footer
        }.frame(width: 400)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
            Text("cc助手").font(.system(size: 14, weight: .semibold))
            Spacer()
            HStack(spacing: 14) {
                Button { egress.check() } label: { Image(systemName: "arrow.clockwise") }.help("重新检测出口").disabled(egress.running)
                Button { openWindow(nil) } label: { Image(systemName: "arrow.up.forward.square") }.help("打开主窗口")
                Button(action: openSettings) { Image(systemName: "gearshape") }.help("设置…")
            }.buttonStyle(.borderless).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    /// One strip, four columns separated by hairlines.
    private var stats: some View {
        HStack(alignment: .top, spacing: 0) {
            // 线路 = Clash subscription enhancements: how many, and whether remote copies are healthy.
            stat("线路", value: "\(subscriptions.records.count) 条", detail: lineDetail.text, tone: lineDetail.tone) { openWindow(.lines) }
            Divider()
            stat("出口", value: egress.exitIPs.first ?? "—", detail: egress.running ? "检测中…" : egress.successful.first?.country.map { "\($0) · \(egress.failedCount > 0 ? "\(egress.failedCount) 项失败" : "检测通过")" } ?? "未检测", hint: egress.failureLines.joined(separator: "\n"),
                 tone: egress.failedCount > 0 ? .orange : .secondary, mono: true) { openWindow(.detection) }
            Divider()
            BrowserStat(model: browsers.active) { openWindow(.browser) }
            Divider()
            stat("账号", value: "\(accounts.activeRecords.count) 个",
                 detail: accounts.invalidSessionCount > 0 ? "\(accounts.invalidSessionCount) 个 Session 失效" : accounts.nearLimitCount > 0 ? "\(accounts.nearLimitCount) 个接近限额" : accounts.expiringSoonCount > 0 ? "\(accounts.expiringSoonCount) 个 7 天内到期" : "无即将到期",
                 tone: accounts.invalidSessionCount > 0 ? .red : accounts.nearLimitCount + accounts.expiringSoonCount > 0 ? .orange : .secondary) { openWindow(.accounts) }
        }.fixedSize(horizontal: false, vertical: true).panelCard()
    }

    /// Which probes failed and why, shown only when something did.
    @ViewBuilder private var egressFailures: some View {
        if !egress.running, !egress.failureLines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(egress.failureLines, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).panelCard()
        }
    }

    private var lineDetail: (text: String, tone: Color) {
        let failed = subscriptions.records.filter { $0.remote?.lastError != nil }.count
        if failed > 0 { return ("\(failed) 条异常", .orange) }
        let published = subscriptions.records.filter { $0.remote != nil }.count
        if subscriptions.records.isEmpty { return ("尚未配置", .secondary) }
        return (published == subscriptions.records.count ? "全部已发布" : published > 0 ? "\(published) 条已发布" : "仅本机订阅", .secondary)
    }

    private func stat(_ title: String, value: String, detail: String, hint: String = "", tone: Color, mono: Bool = false, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            StatCell(title: title, value: value, detail: detail, tone: tone, mono: mono)
        }.buttonStyle(.plain).help(hint.isEmpty ? "在主窗口查看\(title)" : hint + "\n\n点击在主窗口查看明细")
    }

    private var lineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("内置代理").font(.system(size: 12, weight: .semibold))
                Spacer()
                if subscriptions.lineRunning { Text(LineEngine.address).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                Picker("线路", selection: $lineID) {
                    Text("选择线路").tag("")
                    ForEach(subscriptions.lineRecords) { record in Text(record.profile.name).tag(record.id) }
                }.labelsHidden().disabled(subscriptions.lineRunning)
                if subscriptions.lineRunning {
                    Button("停止") { subscriptions.stopLine() }
                } else {
                    Button("启动") { Task { await subscriptions.startLine(lineID) } }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(lineID.isEmpty)
                }
            }
            GateStatusView(subscriptions: subscriptions, egress: egress)
            if !subscriptions.lineStatus.isEmpty && !subscriptions.lineRunning {
                Text(subscriptions.lineStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }.padding(12).panelCard()
    }

    private var actions: some View {
        VStack(spacing: 0) {
            BrowserActions(model: browsers.active)
            ActionRow(title: egress.running ? "正在检测出口…" : "重新检测出口", symbol: "checkmark.shield", disabled: egress.running) { egress.check() }
        }.padding(4).panelCard()
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")).foregroundStyle(.secondary)
            if !updates.version.isEmpty {
                Button(updates.running ? updates.status : "更新到 v\(updates.version)", action: updates.install)
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small).disabled(updates.running)
                    .help("下载签名更新，安装后自动重启；配置会保留")
            } else {
                Button(updates.checking ? "检查中…" : "检查更新", action: updates.checkNow).disabled(updates.checking || updates.running)
            }
            Spacer()
            Button("打开 cc助手") { openWindow(nil) }
            Button("退出") { NSApp.terminate(nil) }.help("退出后本机订阅与内置代理停止")
        }.buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(.primary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.primary.opacity(0.04))
            .overlay(alignment: .top) { Divider() }
    }
}

/// Per-account 5h / 7d utilization from the last account refresh.
private struct AccountUsageCard: View {
    @ObservedObject var accounts: AccountPoolModel
    let open: () -> Void
    // ponytail: first 4 rows, the main window lists the rest
    private var rows: [AccountPoolRecord] {
        Array(accounts.activeRecords.sorted { ($0.identity?.usage?.highest ?? -1) > ($1.identity?.usage?.highest ?? -1) }.prefix(4))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("账号额度").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !accounts.refreshing.isEmpty { ProgressView().controlSize(.mini) }
                Button { accounts.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).font(.system(size: 11))
                    .disabled(accounts.refreshableRecords.isEmpty || !accounts.refreshing.isEmpty).help("刷新已关联账号的 5 小时 / 7 天用量")
            }
            ForEach(rows) { row in
                Button(action: open) { AccountUsageRow(row: row, status: accounts.connectionText(row)) }.buttonStyle(.plain)
            }
            if accounts.activeRecords.count > rows.count {
                Text("另有 \(accounts.activeRecords.count - rows.count) 个账号，在主窗口查看").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(12).panelCard()
    }
}

private struct AccountUsageRow: View {
    let row: AccountPoolRecord, status: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(row.label.isEmpty ? row.email : row.label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if row.sessionInvalidFrom != nil {
                    Text("Session 失效").font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Color.red, in: Capsule())
                }
                if !row.subscription.isEmpty {
                    Text(row.subscription).font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Color.primary.opacity(0.06), in: Capsule())
                }
                Spacer()
                if let usage = row.identity?.usage {
                    Text(Self.updated(usage.checkedAt)).font(.system(size: 10)).foregroundStyle(.tertiary).help("额度读取时间：" + usage.checkedAt.formatted(date: .omitted, time: .shortened))
                }
            }
            if row.sessionInvalidFrom != nil {
                Text("官网返回 401，请在主窗口重新接入").font(.system(size: 10)).foregroundStyle(.red)
            } else if let usage = row.identity?.usage {
                HStack(spacing: 12) {
                    UsageBar(title: "5h", window: usage.fiveHour)
                    UsageBar(title: "7d", window: usage.sevenDay)
                }
                if !usage.sortedModels.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(usage.sortedModels, id: \.name) { UsageBar(title: $0.name, window: $0.window) }
                    }
                }
            } else if row.identity?.plan != "Free" {
                Text(status == "尚未关联" ? "未关联，无法读取额度" : "尚未读取额度，点右上角刷新").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.contentShape(Rectangle()).help(status)
    }
    private static func updated(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        return minutes < 1 ? "刚刚更新" : minutes < 60 ? "\(minutes) 分钟前更新" : "\(minutes / 60) 小时前更新"
    }
}

struct UsageBar: View {
    let title: String, window: AccountUsage.Window?
    private var tone: Color { guard let p = window?.percent else { return .secondary }; return p >= 90 ? .red : p >= 70 ? .orange : .green }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Text(window.map { "\(Int($0.percent.rounded()))%" } ?? "—").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(tone)
                Spacer(minLength: 0)
                if let reset = window?.resetsAt, reset > Date() { Text(Self.reset(reset)).foregroundStyle(.tertiary).help(Self.countdown(reset)) }
            }.font(.system(size: 10))
            // ponytail: drawn bar; the macOS linear ProgressView ignores tint
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tone).frame(width: proxy.size.width * min(max((window?.percent ?? 0) / 100, 0), 1))
                }
            }.frame(height: 4)
        }.frame(maxWidth: .infinity)
    }
    /// Same day: "21:40 重置"; later: "10/23 20:00 重置". Hover shows the countdown.
    static func reset(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        return (Calendar.current.isDateInToday(date) ? time : date.formatted(.dateTime.month(.defaultDigits).day()) + " " + time) + " 重置"
    }
    static func countdown(_ date: Date) -> String {
        let minutes = max(Int(date.timeIntervalSinceNow / 60), 1)
        return minutes < 60 ? "\(minutes) 分钟后" : "\(minutes / 60) 小时 \(minutes % 60) 分钟后"
    }
}

private struct StatCell: View {
    let title: String, value: String, detail: String, tone: Color
    var mono = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: mono ? 14 : 15, weight: .semibold, design: mono ? .monospaced : .default)).lineLimit(1).fixedSize(horizontal: mono, vertical: false)
            Text(detail).font(.system(size: 10)).foregroundStyle(tone == .secondary ? Color.secondary : tone).lineLimit(2)
        }.frame(maxWidth: mono ? nil : .infinity, alignment: .topLeading).padding(10).contentShape(Rectangle())
            .fixedSize(horizontal: mono, vertical: false)  // the IP column takes its natural width
    }
}

private struct BrowserStat: View {
    @ObservedObject var model: RegistrationModel
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            StatCell(title: "浏览器", value: model.browserRuntime.phase.rawValue, detail: model.settings.proxy == LineEngine.address ? "走内置代理" : model.settings.proxy.isEmpty ? "直连" : "代理 " + (URL(string: model.settings.proxy)?.port.map(String.init) ?? model.settings.proxy),
                     tone: model.browserRuntime.phase == .running ? .green : model.browserRuntime.phase == .stopped ? .secondary : .orange)
        }.buttonStyle(.plain).help("在主窗口查看浏览器")
    }
}

private struct BrowserActions: View {
    @ObservedObject var model: RegistrationModel
    private var unavailable: Bool { model.engine == nil || model.openingBrowser || model.browserRuntime.phase == .stopping }
    var body: some View {
        ActionRow(title: model.openingBrowser ? "正在启动浏览器…" : "打开浏览器并检测", symbol: "macwindow", disabled: unavailable) { model.openBrowser(RegistrationModel.browserCheckPage) }
        ActionRow(title: "打开 Claude", symbol: "arrow.up.right.square", disabled: unavailable) { model.openBrowser("https://claude.ai/") }
    }
}

/// Menu-item-like row with hover highlight.
private struct ActionRow: View {
    let title: String, symbol: String
    var disabled = false
    let run: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }.font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 7)
                .background(hovering && !disabled ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.5 : 1).onHover { hovering = $0 }
    }
}

private extension View {
    func panelCard() -> some View {
        background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// Exit health for the menu bar ring: nil = not checked / checking.
enum EgressHealth: Equatable {
    case ok, warning, failed
    static func evaluate(running: Bool, checked: Bool, exits: Int, allUS: Bool, failures: Int, markedChanged: Bool) -> EgressHealth? {
        guard !running, checked else { return nil }
        if exits == 0 || !allUS { return .failed }
        if failures > 0 || exits > 1 || markedChanged { return .warning }
        return .ok
    }
    var color: NSColor { switch self { case .ok: .systemGreen; case .warning: .systemYellow; case .failed: .systemRed } }
    var text: String { switch self { case .ok: "出口正常"; case .warning: "出口需确认"; case .failed: "出口异常" } }
}
extension EgressCheckModel {
    var health: EgressHealth? {
        .evaluate(running: running, checked: !results.isEmpty, exits: exitIPs.count, allUS: ipv6Leak == nil && successful.allSatisfy { $0.country == "US" }, failures: failedCount, markedChanged: markedIPChanged)
    }
}

enum StatusIcon {
    /// Shield with a "C" mark, monochrome like system icons. Filled shield (C knocked out) while the proxy runs;
    /// exit health shows as a small colored dot badge.
    static func image(filled: Bool, health: EgressHealth?) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: filled ? "shield.fill" : "shield", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return NSImage() }
        let size = NSSize(width: symbol.size.width + (health == nil ? 0 : 3), height: max(symbol.size.height, 16))
        let image = NSImage(size: size, flipped: false) { rect in
            let shieldRect = NSRect(x: 0, y: (rect.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
            let shield = NSImage(size: symbol.size, flipped: false) { r in
                symbol.draw(in: r)
                // Template images only use alpha; tinting keeps the colored-badge variant matching the menu bar.
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                let font = NSFont.systemFont(ofSize: r.height * 0.5, weight: .heavy)
                let c = NSAttributedString(string: "C", attributes: [.font: font, .foregroundColor: NSColor.black])
                let cs = c.size()
                // Optical center sits a bit above the box middle because the shield narrows toward its tip.
                let origin = NSPoint(x: r.midX - cs.width / 2, y: r.midY - cs.height / 2 + r.height * 0.04)
                if filled { NSGraphicsContext.current?.compositingOperation = .destinationOut }
                c.draw(at: origin)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                if !filled { NSColor.labelColor.set(); r.fill(using: .sourceAtop) }
                return true
            }
            shield.draw(in: shieldRect)
            if let health {
                let d: CGFloat = 7, dot = NSRect(x: rect.width - d, y: 0.5, width: d, height: d)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                health.color.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = health == nil
        image.accessibilityDescription = "cc助手，" + (filled ? "内置代理运行中" : "内置代理未启动") + (health.map { "，\($0.text)" } ?? "")
        return image
    }
}

/// Gate state line for the built-in proxy, with the two recovery actions.
struct GateStatusView: View {
    @ObservedObject var subscriptions: SubscriptionModel
    @ObservedObject var egress: EgressCheckModel
    var body: some View {
        switch subscriptions.gate {
        case .idle: EmptyView()
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在核验出口…") }.font(.caption).foregroundStyle(.secondary)
        case .open(let reason):
            Label("已放行 · \(reason)", systemImage: "checkmark.shield.fill").font(.caption).foregroundStyle(.green)
        case .blocked(let reason, let exit):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "xmark.shield.fill").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let exit, exit != egress.markedIP {
                        Button("设为标记 IP") { egress.markVerified(exit); Task { await subscriptions.verifyGate() } }
                            .help("确认 \(exit) 是你要使用的出口后再标记")
                    }
                    Button("重新核验") { Task { await subscriptions.verifyGate() } }
                }.controlSize(.small)
            }
        }
    }
}
