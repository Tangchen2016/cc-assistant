import SwiftUI
import AppKit

private actor EgressProbeSlots {
    private var remaining = 6
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if remaining > 0 { remaining -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { remaining += 1 }
        else { waiting.removeFirst().resume() }
    }
}

@MainActor final class EgressCheckModel: ObservableObject {
    @Published var proxy = "" { didSet { if proxy != oldValue { clearResults() } } }
    @Published var proxyEnabled = false { didSet { if proxyEnabled != oldValue { clearResults() } } }
    @Published var results: [String: [EgressProbeKind: EgressProbeResult]] = [:]
    @Published var running = false
    @Published var pending: Set<String> = []
    @Published var status = "尚未检测"
    @Published var lastCheck: Date?
    @Published var copied = false
    @Published var historyExpanded = false
    @Published var resultsExpanded = false
    @Published var showMobileCheck = false
    @Published var mobileLinkCopied = false
    @Published var history: EgressIPHistory
    let markerStore: EgressMarkedIPStore
    init(history: EgressIPHistory = EgressIPHistory(), markerFile: URL? = nil) {
        self.history = history
        markerStore = EgressMarkedIPStore(fileURL: markerFile ?? (history.fileURL == EgressIPHistory.defaultFile ? EgressMarkedIPStore.defaultFile : history.fileURL.appendingPathExtension("marked-ip.json")))
        if history.fileURL == EgressIPHistory.defaultFile && !markerStore.hasStoredState {
            let fingerprints = Set(defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("baseline.") }.compactMap { $0.value as? String })
            if let ip = EgressMarkedIPStore.legacyCandidate(fingerprints: fingerprints, knownIPs: history.uniqueIPs) { try? markerStore.mark(ip) }
        }
    }
    var markedIP: String? { markerStore.marker?.ip }
    var markedIPChanged: Bool { markedIP.map { marker in exitIPs.contains { $0 != marker } } ?? false }
    var markerComparison: String {
        guard markedIP != nil else { return "标记后，后续检测将与此 IP 对比。" }
        if running { return "正在检测，完成后与标记 IP 对比。" }
        if exitIPs.isEmpty { return "后续检测将与此 IP 对比。" }
        if markedIPChanged { return "IP 已变更：存在与标记不同的出口。" }
        return failedCount > 0 ? "已取得的出口与标记一致，仍有未验证项。" : "已检测的出口与标记一致。"
    }
    func markIP(_ value: String) {
        guard !running, let ip = EgressIPHistory.normalized(value), exitIPs.contains(ip) else { return }
        do { try markerStore.mark(ip); objectWillChange.send(); status = "已标记 \(ip)，新标记会替换旧标记。" }
        catch { status = error.localizedDescription }
    }
    /// Marks an exit verified through the built-in proxy (not necessarily in the last full check).
    func markVerified(_ value: String) {
        guard let ip = EgressIPHistory.normalized(value) else { return }
        do { try markerStore.mark(ip); objectWillChange.send(); status = "已标记 \(ip)，新标记会替换旧标记。" }
        catch { status = error.localizedDescription }
    }
    func clearMarkedIP() {
        guard !running else { return }
        do { try markerStore.clear(); objectWillChange.send(); status = "已取消 IP 标记" }
        catch { status = error.localizedDescription }
    }
    @Published var previousIPs: [String: String] = [:]
    private let defaults = UserDefaults(suiteName: "local.subscription.studio.egress") ?? .standard
    private let slots = EgressProbeSlots()
    var successful: [EgressProbeResult] { EgressLocalDiagnostics.hosts.flatMap { host in tableKinds.compactMap { results[host]?[$0] }.filter(\.isSuccess) } }
    /// IPv6 is a single leak check, not a per-host path: leaked or not. Unreachable IPv6 means nothing leaks.
    static let ipv6Host = EgressLocalDiagnostics.commonHosts[0]
    var ipv6Result: EgressProbeResult? { results[Self.ipv6Host]?[.ipv6] }
    /// A non-US exit over raw IPv6 means Claude traffic can bypass the proxy.
    var ipv6Leak: EgressProbeResult? { ipv6Result.flatMap { $0.isSuccess && $0.country != "US" ? $0 : nil } }
    var tableKinds: [EgressProbeKind] { enabledKinds.filter { $0 != .ipv6 } }
    func probeTargets(_ hosts: [String], kinds: [EgressProbeKind]) -> [(host: String, kind: EgressProbeKind)] {
        kinds.flatMap { kind in (kind == .ipv6 ? hosts.filter { $0 == Self.ipv6Host } : hosts).map { (host: $0, kind: kind) } }
    }
    var completed: Int { results.values.reduce(0) { $0 + $1.count } }
    /// The managed browser is checked on its own page when it opens, not in this machine-wide check.
    /// Claude's own proxy settings; without one the simulation has nothing to simulate, so the row is hidden.
    @Published private(set) var claudeProxyConfigured = EgressCheckModel.readClaudeProxy()
    private static func readClaudeProxy() -> Bool { let env = EgressLocalDiagnostics.claudeNetworkEnvironment(); return ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"].contains { !(env[$0] ?? "").isEmpty } }
    var enabledKinds: [EgressProbeKind] { EgressProbeKind.allCases.filter { $0 != .browser && (proxyEnabled || $0 != .proxy) && (claudeProxyConfigured || $0 != .claude) } }
    var expectedCount: Int { probeTargets(EgressLocalDiagnostics.hosts, kinds: enabledKinds).count }
    func resultKey(_ host: String, _ kind: EgressProbeKind) -> String { "\(host)|\(kind.rawValue)" }
    var hasChanged: Bool {
        if markedIP != nil { return markedIPChanged }
        return !previousIPs.isEmpty || EgressLocalDiagnostics.hosts.contains { host in normalKinds.contains { kind in results[host]?[kind].map { changed($0, host: host) } ?? false } }
    }
    var changeNotice: String {
        if markedIPChanged { return "存在与标记 IP 不同的出口，展开明细查看。" }
        return previousIPs.isEmpty ? "部分结果与旧基准不同，展开明细查看。" : "本次有 \(previousIPs.count) 条路径的 IP 变更，展开明细查看。"
    }
    var normalKinds: [EgressProbeKind] { enabledKinds.filter { $0 != .ipv4 && $0 != .ipv6 } }
    var normalSuccessful: [EgressProbeResult] { EgressLocalDiagnostics.hosts.flatMap { host in normalKinds.compactMap { results[host]?[$0] }.filter(\.isSuccess) } }
    func clearResults() {
        guard !running else { return }
        generation += 1; backgroundRunning = false; backgroundPending = 0
        results = [:]; previousIPs = [:]; lastCheck = nil; status = "设置已改变，请重新检测"
    }
    func baselineKey(_ host: String, _ kind: EgressProbeKind) -> String { "baseline.\(host).\(kind.rawValue)" }
    func changed(_ row: EgressProbeResult, host: String) -> Bool {
        if let markedIP, let ip = row.ip.flatMap(EgressIPHistory.normalized) { return ip != markedIP }
        if previousIPs[resultKey(host, row.kind)] != nil { return true }
        guard !markerStore.hasStoredState else { return false }
        guard let fingerprint = row.fingerprint, let baseline = defaults.string(forKey: baselineKey(host, row.kind)) else { return false }
        return fingerprint != baseline
    }
    var rows: [EgressProbeResult] { EgressLocalDiagnostics.hosts.flatMap { host in tableKinds.compactMap { results[host]?[$0] } } }
    var skippedCount: Int { rows.filter { $0.skippedReason != nil }.count }
    var failedCount: Int { rows.filter { !$0.isSuccess && $0.skippedReason == nil }.count }
    /// Failed rows grouped by path and reason, e.g. "默认 curl · 请求超时：claude.com、platform.claude.com".
    var failureLines: [String] {
        var groups: [(key: String, hosts: [String])] = []
        for kind in tableKinds {
            for host in EgressLocalDiagnostics.hosts {
                guard let row = results[host]?[kind], !row.isSuccess, row.skippedReason == nil else { continue }
                let key = "\(kind.title) · \(EgressAIPrompt.failure(row))"
                if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].hosts.append(host) } else { groups.append((key, [host])) }
            }
        }
        return groups.map { "\($0.key)：\($0.hosts.joined(separator: "、"))" }
    }
    var exitIPs: [String] { Array(Set(successful.compactMap { $0.ip.flatMap(EgressIPHistory.normalized) })).sorted() }
    var summary: String {
        if running { return "正在检测出口" }
        if results.isEmpty { return "准备检查网络出口" }
        if successful.isEmpty { return "尚未取得有效出口" }
        if ipv6Leak != nil { return "IPv6 绕过代理，出口不在美国" }
        if markedIPChanged { return "出口与标记 IP 不一致" }
        if successful.contains(where: { $0.country != "US" }) { return "检测到非美国出口" }
        if exitIPs.count > 1 { return "检测到多个出口 IP" }
        if failedCount > 0 { return "已取得出口，部分检测失败" }
        return "已检测的出口一致"
    }
    var summaryColor: Color {
        if results.isEmpty || running { return egressAccent }
        return ipv6Leak == nil && !markedIPChanged && failedCount == 0 && !successful.isEmpty && successful.allSatisfy({ $0.country == "US" }) && exitIPs.count == 1 ? egressSuccess : .orange
    }
    /// A silent background refresh is in flight; the UI keeps showing the previous results.
    @Published var backgroundRunning = false
    var busy: Bool { running || backgroundRunning }
    private var backgroundPending = 0
    /// Bumped by a visible check so a stale background refresh can't write into the fresh results.
    private var generation = 0
    private func probe(_ kind: EgressProbeKind, host: String, proxy: String) async -> EgressProbeResult {
        await slots.acquire()
        func once() async -> EgressProbeResult { await Task.detached(priority: .utility) { EgressLocalDiagnostics.curlProbe(kind: kind, host: host, proxy: proxy) }.value }
        var result = await once()
        if result.timedOut {
            let initialMilliseconds = result.milliseconds
            result = await once()
            result.attempts = 2; result.milliseconds += initialMilliseconds
        }
        await slots.release()
        return result
    }
    /// Whether the latest check was started by the user; only those run the full 16-domain route scan.
    @Published private(set) var lastRunManual = false
    func check(hosts: [String] = EgressLocalDiagnostics.hosts, manual: Bool = true) {
        guard !running else { return }
        generation += 1; backgroundRunning = false; backgroundPending = 0
        history.prune(); previousIPs = [:]
        claudeProxyConfigured = Self.readClaudeProxy()
        lastRunManual = manual
        results = [:]; pending = Set(probeTargets(hosts, kinds: enabledKinds).map { resultKey($0.host, $0.kind) }); running = true
        let proxy = proxy
        for (host, kind) in probeTargets(hosts, kinds: enabledKinds) {
            Task {
                let result = await probe(kind, host: host, proxy: proxy)
                if let old = history.record(result, host: host) { previousIPs[resultKey(host, kind)] = old }
                results[host, default: [:]][kind] = result; pending.remove(resultKey(host, kind))
                finishIfComplete()
            }
        }
    }
    /// Re-probes `hosts` in the background without clearing what's on screen; rows are replaced as they land.
    /// Falls back to a visible check when there is nothing to show yet.
    func refreshSilently(hosts: [String]) {
        guard !busy else { return }
        guard !results.isEmpty else { check(hosts: hosts, manual: false); return }
        lastRunManual = false
        claudeProxyConfigured = Self.readClaudeProxy()
        history.prune()
        let gen = generation, proxy = proxy, targets = probeTargets(hosts, kinds: enabledKinds)
        backgroundPending = targets.count
        guard backgroundPending > 0 else { return }
        backgroundRunning = true
        for (host, kind) in targets {
            Task {
                let result = await probe(kind, host: host, proxy: proxy)
                guard gen == generation else { return }
                if let old = history.record(result, host: host) { previousIPs[resultKey(host, kind)] = old }
                results[host, default: [:]][kind] = result
                finishBackground()
            }
        }
    }
    private func finishBackground() {
        backgroundPending -= 1
        guard backgroundPending == 0 else { return }
        backgroundRunning = false; lastCheck = Date()
    }
    private func finishIfComplete() {
        guard pending.isEmpty else { return }
        running = false; lastCheck = Date(); status = "\(EgressLocalDiagnostics.hosts.count) 个地址、\(expectedCount) 条路径检测完成"
    }
    func saveBaseline() {
        for host in EgressLocalDiagnostics.hosts {
            for row in results[host]?.values ?? Dictionary<EgressProbeKind, EgressProbeResult>().values where row.isSuccess && row.country == "US" { defaults.set(row.fingerprint, forKey: baselineKey(host, row.kind)) }
        }
        objectWillChange.send(); status = "已记录美国出口基准，仅保存 IP 摘要"
    }
    var diagnosticSummary: String {
        var lines = ["Anthropic 出口检测", "目标：\(EgressLocalDiagnostics.hosts.joined(separator: "、"))", "代理配置开关：\(proxyEnabled ? "开启" : "关闭")", "时间：\(lastCheck?.formatted(date: .numeric, time: .standard) ?? "未检测")", "结论：\(summary)", "范围：App 启动环境的 curl 与 Claude 全局配置模拟；浏览器出口请在独立浏览器检测页核对。IPv4/IPv6 为绕过显式代理的对照项。"]
        for host in EgressLocalDiagnostics.hosts {
            lines.append("\n\(host)")
            for kind in EgressProbeKind.allCases {
                guard let row = results[host]?[kind] else { continue }
                lines.append("\(kind.title)：\(row.maskedIP) · \(row.country ?? "未知") · \(row.milliseconds) ms\((row.error ?? row.skippedReason).map { " · " + $0 } ?? "")")
            }
        }
        lines.append("出口检测不等于登录或模型 API 验收；摘要不包含完整 IP、Cookie、邮箱或账户信息。")
        return lines.joined(separator: "\n")
    }
    func copySummary() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnosticSummary, forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
    }
}

private let egressAccent = Theme.accent
private let egressSuccess = Color(red: 34 / 255, green: 119 / 255, blue: 91 / 255)

private struct EgressCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

private struct EgressCircleButton: View {
    @ObservedObject var model: EgressCheckModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: model.running ? 1.0 / 30 : 1.0 / 15, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let pulse = (sin(time * .pi * 2 / (model.running ? 1.8 : 3.2)) + 1) / 2
            let ripple = time.truncatingRemainder(dividingBy: model.running ? 1.8 : 3.6) / (model.running ? 1.8 : 3.6)
            let rotation = time.truncatingRemainder(dividingBy: model.running ? 3 : 16) / (model.running ? 3 : 16) * 360
            ZStack {
                Circle().stroke(egressAccent.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: [2, 4])).frame(width: 160, height: 160)
                Circle().fill(egressAccent.opacity(0.045 + pulse * 0.025)).frame(width: 136 + pulse * 9, height: 136 + pulse * 9).blur(radius: 9)
                Circle().stroke(egressAccent.opacity(0.12 + pulse * 0.05), lineWidth: 1).frame(width: 128 + pulse * 7, height: 128 + pulse * 7)
                if !reduceMotion {
                    Circle().stroke(egressAccent.opacity((1 - ripple) * 0.18), lineWidth: 1)
                        .frame(width: 122 + ripple * 56, height: 122 + ripple * 56)
                    ZStack {
                        Circle().fill(egressAccent.opacity(0.65)).frame(width: 5, height: 5).offset(y: -80)
                        Circle().fill(egressAccent.opacity(0.3)).frame(width: 3, height: 3).offset(y: 80)
                    }.rotationEffect(.degrees(rotation))
                }
                Button(action: { model.check() }) {
                    ZStack {
                        Circle().fill(RadialGradient(colors: [Color(red: 0.8, green: 0.45, blue: 0.32), egressAccent], center: .topLeading, startRadius: 0, endRadius: 125))
                        Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1).padding(1)
                        if model.running {
                            Circle().stroke(.white.opacity(0.25), lineWidth: 3).padding(6)
                            Circle().trim(from: 0, to: CGFloat(model.completed) / CGFloat(max(1, model.expectedCount)))
                                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90)).padding(6)
                        }
                        VStack(spacing: 5) {
                            if model.running {
                                Text("\(model.completed) / \(model.expectedCount)").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                            }
                            Text(model.running ? "检测中" : model.results.isEmpty ? "开始检测" : "重新检测")
                                .font(.system(size: model.running ? 11 : 14, weight: .semibold))
                        }.foregroundStyle(.white)
                    }.frame(width: 112, height: 112).contentShape(Circle())
                        .shadow(color: egressAccent.opacity(0.19), radius: 14, y: 7)
                }.buttonStyle(EgressCircleButtonStyle()).disabled(model.running)
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityLabel(model.running ? "正在检测 \(model.completed) / \(model.expectedCount)" : model.results.isEmpty ? "开始检测" : "重新检测")
            }.frame(width: 184, height: 184)
        }.frame(width: 184, height: 184)
    }
}

struct EgressDetectionView: View {
    @ObservedObject var model: EgressCheckModel
    @Environment(\.colorScheme) private var colorScheme
    var onEnhancement: () -> Void = {}
    var clash: ClashObserver? = nil
    private let pathWidth: CGFloat = 192
    private var pageBackground: Color { Color(nsColor: .windowBackgroundColor) }
    private var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    private var verified: Bool { !model.running && model.ipv6Leak == nil && !model.markedIPChanged && !model.successful.isEmpty && model.failedCount == 0 && model.exitIPs.count == 1 && model.successful.allSatisfy { $0.country == "US" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    hero
                    if !verified { overview }
                    markedIPInformation
                    controls
                    DisclosureGroup(isExpanded: $model.resultsExpanded) {
                        resultTable.padding(.top, 14).padding(.bottom, 8)
                    } label: {
                        HStack {
                            Text("检测明细").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(EgressLocalDiagnostics.hosts.count) 个域名 · \(model.tableKinds.count) 条路径").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }
                        .overlay(alignment: .top) { Divider().opacity(0.4) }
                        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
                    if let clash { RouteCoverageView(clash: clash, egress: model) }
                    HStack(spacing: 14) {
                        Button(model.copied ? "已复制 AI 排查提示词" : "复制 AI 排查提示词", action: model.copyAIPrompt).disabled(model.running || model.results.isEmpty)
                            .help("包含本次脱敏检测结果，可粘贴到你选用的 AI；只复制到剪贴板，不自动发送。")
                        Spacer()
                        Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    }.buttonStyle(.bordered).controlSize(.small).font(.system(size: 11))
                    DisclosureGroup(isExpanded: $model.historyExpanded) {
                        historyView.padding(.top, 12)
                    } label: {
                        HStack(spacing: 10) {
                            Text("IP 历史").font(.system(size: 13, weight: .semibold))
                            Text("\(model.history.uniqueIPs.count) 个去重记录").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }.tint(.secondary)
                }.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 28).frame(maxWidth: Theme.contentWidth)
                    .frame(maxWidth: .infinity)
            }
            Divider().opacity(0.4)
            Label("只读检测 · 无登录 Cookie · 历史仅保存在本机", systemImage: "lock.shield")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 9)
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(pageBackground)
        .sheet(isPresented: $model.showMobileCheck) { MobileCheckEntrySheet(model: model) }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in model.history.prune() }
    }
    private var header: some View {
        PageHeader(title: "检测") {
            Button { model.mobileLinkCopied = false; model.showMobileCheck = true } label: { Label("手机检测…", systemImage: "iphone.and.arrow.forward") }.help("用手机检测出口")
            Button(action: onEnhancement) { Label("线路", systemImage: "arrow.triangle.branch") }.help("前往线路")
        }
    }
    private var hero: some View {
        VStack(spacing: 12) {
            if verified {
                Label("出口检测通过", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(egressSuccess)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(egressSuccess.opacity(0.08), in: Capsule())
                Text("可以开始访问 Claude").font(.system(size: 26, weight: .bold)).tracking(-0.4)
                Text("当前已检测的线路出口一致。").font(.system(size: 13)).foregroundStyle(.secondary)
                if let ip = model.exitIPs.first {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(ip).font(.system(size: 30, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(1).minimumScaleFactor(0.65)
                        Text("美国 US").font(.system(size: 12, weight: .medium)).foregroundStyle(egressSuccess)
                    }.padding(.top, 4)
                }
                Text("\(model.successful.count) 项成功 · \(model.skippedCount) 项跳过 · \(model.lastCheck.map { $0.formatted(date: .omitted, time: .shortened) } ?? "") 检测")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if model.hasChanged {
                    Label(model.changeNotice, systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                Text("未验证项可在明细中查看；出口检测不代表完整登录或服务可用性验证。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("确认你的 Claude 网络出口").font(.system(size: 26, weight: .bold)).tracking(-0.4)
                if let leak = model.ipv6Leak {
                    Label("IPv6 未经代理：\(leak.ip ?? "")（\(leak.country ?? "未知")）。请在代理客户端开启 IPv6 接管，或在系统网络设置中关闭 IPv6。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.red).multilineTextAlignment(.center).textSelection(.enabled)
                }
                Text("核对浏览器与本地请求，看看正在从哪里连接。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            EgressCircleButton(model: model).padding(.top, 3)
        }.frame(maxWidth: .infinity).padding(.top, 10).padding(.bottom, verified ? 6 : 0)
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(model.lastCheck.map { $0.formatted(date: .numeric, time: .shortened) } ?? "仅访问公开出口检测接口")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if !model.results.isEmpty && !model.running {
                    Label(verified ? "检测成功" : "需要确认", systemImage: verified ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(model.summaryColor)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(model.summaryColor.opacity(0.09), in: Capsule())
                }
            }
            Text(model.summary).font(.system(size: 18, weight: .semibold))
            if model.exitIPs.isEmpty {
                Text(model.running ? "正在读取各条请求路径的出口…" : "开始检测后，这里会显示出口 IP 和地区。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                ForEach(model.exitIPs, id: \.self) { ip in
                    let countries = Array(Set(model.successful.filter { $0.ip.flatMap(EgressIPHistory.normalized) == ip }.compactMap(\.country))).sorted()
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(ip).font(.system(size: 28, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(1).minimumScaleFactor(0.65)
                        Text(countries.map { $0 == "US" ? "美国 US" : $0 }.joined(separator: " / "))
                            .font(.system(size: 12)).foregroundStyle(model.summaryColor)
                    }
                }
            }
            HStack {
                Text(model.results.isEmpty ? "期望出口 · 美国" : model.running ? "\(model.completed) / \(model.expectedCount) 已完成" : "\(model.successful.count) 项成功 · \(model.skippedCount) 项跳过\(model.failedCount > 0 ? " · \(model.failedCount) 项失败" : "")")
                Spacer()
                Text("出口检测不代表完整登录或服务可用性验证。")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            if model.hasChanged && !model.results.isEmpty {
                Label(model.changeNotice, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(verified ? egressSuccess.opacity(0.35) : Color(nsColor: .separatorColor), lineWidth: verified ? 1 : 0.5))
    }
    private var controls: some View {
        HStack(spacing: 12) {
            Text("检测范围").foregroundStyle(.secondary)
            Text("Anthropic API · Claude 网页 · 登录授权 · 开发平台").help(EgressLocalDiagnostics.hosts.joined(separator: " · "))
            Spacer()
            Toggle("自定义代理", isOn: $model.proxyEnabled).toggleStyle(.switch).controlSize(.small)
            if model.proxyEnabled { TextField("http://代理地址:端口", text: $model.proxy).textFieldStyle(.roundedBorder).frame(width: 220) }
        }.font(.system(size: 11)).disabled(model.running)
    }
    private var markedIPInformation: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Label("标记 IP", systemImage: "pin").font(.system(size: 12, weight: .medium))
                Text(model.markedIP ?? "尚未标记").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer()
                if model.exitIPs.count == 1, let ip = model.exitIPs.first {
                    Button(model.markedIP == ip ? "已标记此 IP" : model.markedIP == nil ? "标记此 IP" : "替换标记", action: { model.markIP(ip) })
                        .disabled(model.running || model.markedIP == ip)
                } else {
                    Menu(model.markedIP == nil ? "选择要标记的 IP" : "替换标记") {
                        ForEach(model.exitIPs, id: \.self) { ip in Button(ip) { model.markIP(ip) } }
                    }.disabled(model.running || model.exitIPs.isEmpty)
                }
                if model.markedIP != nil { Button("取消标记", action: model.clearMarkedIP).disabled(model.running) }
            }.buttonStyle(.borderless).font(.system(size: 11)).tint(egressAccent)
            Text(model.markerStore.warning ?? model.markerComparison).font(.system(size: 11))
                .foregroundStyle(model.markedIPChanged ? Color.orange : Color.secondary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(model.markedIPChanged ? Color.orange.opacity(0.4) : Color(nsColor: .separatorColor), lineWidth: model.markedIPChanged ? 1 : 0.5))
    }
    private func pathLabel(_ kind: EgressProbeKind) -> some View {
        HStack(spacing: 9) {
            Image(systemName: kind.symbol).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 17)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.system(size: 12, weight: .medium))
            }
        }.help(kind.detail).frame(width: pathWidth, alignment: .leading).padding(.horizontal, 14)
    }
    private func skippedReason(_ kind: EgressProbeKind) -> String? {
        let rows = EgressLocalDiagnostics.hosts.compactMap { model.results[$0]?[kind] }
        guard rows.count == EgressLocalDiagnostics.hosts.count, rows.allSatisfy({ $0.skippedReason != nil }) else { return nil }
        return rows.first?.skippedReason
    }
    private var resultTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("请求路径").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: pathWidth, alignment: .leading).padding(.horizontal, 14)
                ForEach(EgressLocalDiagnostics.hosts, id: \.self) { host in
                    Text(host).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 13)
                }
            }.background(Color.primary.opacity(0.025))
            Divider().opacity(0.5)
            ForEach(model.tableKinds) { kind in
                HStack(alignment: .center, spacing: 0) {
                    pathLabel(kind)
                    if let reason = skippedReason(kind) {
                        DisclosureGroup {
                            Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
                        } label: {
                            Text("未配置 · 已跳过").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.tint(.secondary).padding(.horizontal, 12).padding(.vertical, 17).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(EgressLocalDiagnostics.hosts, id: \.self) { host in
                            EgressProbeCell(row: model.results[host]?[kind], previousIP: model.previousIPs[model.resultKey(host, kind)], pending: model.pending.contains(model.resultKey(host, kind)), changed: model.results[host]?[kind].map { model.changed($0, host: host) } ?? false, enabled: true)
                        }
                    }
                }
                if kind != model.tableKinds.last { Divider().opacity(0.4) }
            }
        }.background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
    private var historyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = model.history.warning { Text(warning).font(.system(size: 11)).foregroundStyle(.orange) }
            VStack(spacing: 0) {
                if model.history.uniqueIPs.isEmpty { Text("成功检测后自动记录 IP 变化。").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                ForEach(model.history.uniqueIPs, id: \.self) { ip in
                    DisclosureGroup {
                        Text(model.history.sources(ip)).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).textSelection(.enabled)
                    } label: {
                        HStack(spacing: 12) {
                            Text(ip).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                            Text(model.history.isLatestIP(ip) ? "路径最新" : "历史").font(.system(size: 10)).foregroundStyle(.secondary)
                                .help("各请求路径最后一次成功检测的 IP；不代表本次检测结果")
                            Spacer()
                            Text("\(model.history.records.filter { $0.ip == ip }.count) 条关联路径").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(model.history.lastSeen(ip).formatted(date: .numeric, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 125, alignment: .trailing)
                        }
                    }.tint(.secondary).padding(.horizontal, 14).padding(.vertical, 11)
                    if ip != model.history.uniqueIPs.last { Divider().opacity(0.35) }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            Text("每条路径保留最新 IP；被替代的记录在 24 小时后清理。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct EgressProbeCell: View {
    let row: EgressProbeResult?
    let previousIP: String?
    let pending: Bool
    let changed: Bool
    let enabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !enabled { Text("未启用").font(.system(size: 11)).foregroundStyle(.secondary) }
            else if pending { ProgressView().controlSize(.small) }
            else if let row {
                if let reason = row.skippedReason { Text("已跳过").font(.system(size: 11)).foregroundStyle(.secondary).help(reason) }
                else if let error = row.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).help(error).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(previousIP.map { "\($0) → \(row.ip ?? "—")" } ?? row.ip ?? "—")
                        .foregroundStyle(previousIP == nil ? Color.primary : .orange)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(spacing: 10) {
                        Text(row.country == "US" ? "美国 US" : row.country ?? "未知").foregroundStyle(row.country == "US" ? egressSuccess : .orange)
                        Text("\(row.milliseconds) ms").foregroundStyle(.secondary)
                        if changed && previousIP == nil { Text("基准变化").foregroundStyle(.orange) }
                    }.font(.system(size: 10))
                }
                if row.attempts > 1 { Text(row.isSuccess ? "重试后成功" : "已重试 1 次").font(.system(size: 10)).foregroundStyle(.secondary) }
            } else { Text("未检测").font(.system(size: 11)).foregroundStyle(.secondary) }
        }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 12)
    }
}
