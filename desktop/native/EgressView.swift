import SwiftUI
import AppKit
import WebKit

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
    @Published var history = EgressIPHistory()
    @Published var previousIPs: [String: String] = [:]
    private let defaults = UserDefaults(suiteName: "local.subscription.studio.egress") ?? .standard
    private let slots = EgressProbeSlots()
    var successful: [EgressProbeResult] { EgressLocalDiagnostics.hosts.flatMap { host in EgressProbeKind.allCases.compactMap { results[host]?[$0] }.filter(\.isSuccess) } }
    var completed: Int { results.values.reduce(0) { $0 + $1.count } }
    var enabledKinds: [EgressProbeKind] { EgressProbeKind.allCases.filter { proxyEnabled || $0 != .proxy } }
    var expectedCount: Int { EgressLocalDiagnostics.hosts.count * enabledKinds.count }
    func resultKey(_ host: String, _ kind: EgressProbeKind) -> String { "\(host)|\(kind.rawValue)" }
    var hasChanged: Bool { !previousIPs.isEmpty || EgressLocalDiagnostics.hosts.contains { host in normalKinds.contains { kind in results[host]?[kind].map { changed($0, host: host) } ?? false } } }
    var normalKinds: [EgressProbeKind] { enabledKinds.filter { $0 != .ipv4 && $0 != .ipv6 } }
    var normalSuccessful: [EgressProbeResult] { EgressLocalDiagnostics.hosts.flatMap { host in normalKinds.compactMap { results[host]?[$0] }.filter(\.isSuccess) } }
    func clearResults() {
        guard !running else { return }
        results = [:]; previousIPs = [:]; lastCheck = nil; status = "设置已改变，请重新检测"
    }
    func baselineKey(_ host: String, _ kind: EgressProbeKind) -> String { "baseline.\(host).\(kind.rawValue)" }
    func changed(_ row: EgressProbeResult, host: String) -> Bool {
        if previousIPs[resultKey(host, row.kind)] != nil { return true }
        guard let fingerprint = row.fingerprint, let baseline = defaults.string(forKey: baselineKey(host, row.kind)) else { return false }
        return fingerprint != baseline
    }
    var summary: String {
        if running { return "正在并行检测 3 个地址 · \(completed) / \(expectedCount)" }
        if results.isEmpty { return "先核对出口，再使用已登录会话" }
        if !previousIPs.isEmpty { return "检测到 \(previousIPs.count) 条路径的出口 IP 变更" }
        if normalSuccessful.isEmpty { return "未取得常用路径的可验证出口信息" }
        if normalSuccessful.contains(where: { $0.country != "US" }) { return "常用请求路径有非美国出口" }
        if hasChanged { return "检测到出口 IP 与基准不同" }
        if Set(normalSuccessful.compactMap(\.ip)).count > 1 { return "常用请求路径的出口 IP 不一致" }
        let expected = normalKinds.count * EgressLocalDiagnostics.hosts.count
        return normalSuccessful.count == expected ? "3 个地址的常用路径为同一个美国出口" : "\(normalSuccessful.count) / \(expected) 条常用路径为同一个美国出口，仍有未验证项"
    }
    var summaryColor: Color {
        if results.isEmpty || running { return .secondary }
        return normalSuccessful.count == normalKinds.count * EgressLocalDiagnostics.hosts.count && normalSuccessful.allSatisfy({ $0.country == "US" }) && !hasChanged && Set(normalSuccessful.compactMap(\.ip)).count == 1 ? .green : .orange
    }
    func check() {
        guard !running else { return }
        history.prune(); previousIPs = [:]
        results = [:]; pending = Set(EgressLocalDiagnostics.hosts.flatMap { host in enabledKinds.map { resultKey(host, $0) } }); running = true
        let proxy = proxy
        for kind in enabledKinds {
            for host in EgressLocalDiagnostics.hosts {
                Task {
                    await slots.acquire()
                    var result: EgressProbeResult
                    if kind == .browser { let browser = EgressBrowserProbe(); result = await browser.check(host: host) }
                    else { result = await Task.detached(priority: .utility) { EgressLocalDiagnostics.curlProbe(kind: kind, host: host, proxy: proxy) }.value }
                    if result.timedOut {
                        let initialMilliseconds = result.milliseconds
                        if kind == .browser { let browser = EgressBrowserProbe(); result = await browser.check(host: host) }
                        else { result = await Task.detached(priority: .utility) { EgressLocalDiagnostics.curlProbe(kind: kind, host: host, proxy: proxy) }.value }
                        result.attempts = 2; result.milliseconds += initialMilliseconds
                    }
                    await slots.release()
                    if let old = history.record(result, host: host) { previousIPs[resultKey(host, kind)] = old }
                    results[host, default: [:]][kind] = result; pending.remove(resultKey(host, kind))
                    if pending.isEmpty { running = false; lastCheck = Date(); status = "3 个地址、\(expectedCount) 条路径检测完成" }
                }
            }
        }
    }
    func saveBaseline() {
        for host in EgressLocalDiagnostics.hosts {
            for row in results[host]?.values ?? Dictionary<EgressProbeKind, EgressProbeResult>().values where row.isSuccess && row.country == "US" { defaults.set(row.fingerprint, forKey: baselineKey(host, row.kind)) }
        }
        objectWillChange.send(); status = "已记录美国出口基准，仅保存 IP 摘要"
    }
    var diagnosticSummary: String {
        var lines = ["Anthropic 出口检测", "目标：\(EgressLocalDiagnostics.hosts.joined(separator: "、"))", "代理配置开关：\(proxyEnabled ? "开启" : "关闭")", "时间：\(lastCheck?.formatted(date: .numeric, time: .standard) ?? "未检测")", "结论：\(summary)", "范围：App 启动环境的 curl、Claude 全局配置模拟、独立无登录 WebKit；未验证已有浏览器登录会话。IPv4/IPv6 为绕过显式代理的对照项。"]
        for host in EgressLocalDiagnostics.hosts {
            lines.append("\n\(host)")
            for kind in EgressProbeKind.allCases {
                guard let row = results[host]?[kind] else { continue }
                lines.append("\(kind.title)：\(row.maskedIP) · \(row.country ?? "未知") · \(row.milliseconds) ms\(row.error.map { " · " + $0 } ?? "")")
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

private let egressAccent = Color(red: 8 / 255, green: 123 / 255, blue: 120 / 255)

private struct EgressPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).padding(.horizontal, 13).frame(height: 31)
            .foregroundStyle(.white).background(egressAccent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct EgressDetectionView: View {
    @ObservedObject var model: EgressCheckModel
    private let pathWidth: CGFloat = 196
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 24).padding(.vertical, 20)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    controls
                    HStack(spacing: 8) {
                        Circle().fill(model.running ? egressAccent : model.summaryColor).frame(width: 6, height: 6)
                        Text(model.summary).font(.system(size: 12)).foregroundStyle(model.summaryColor)
                        Spacer()
                        Text("并行检测").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("检测结果").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("3 个地址 · 6 条请求路径").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        resultTable
                        HStack {
                            Button("记录美国出口基准", action: model.saveBaseline).disabled(model.running || !model.successful.contains(where: { $0.country == "US" }))
                            Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button(model.copied ? "已复制" : "复制脱敏摘要", action: model.copySummary).disabled(model.running || model.results.isEmpty)
                        }.font(.system(size: 11)).controlSize(.small).padding(.top, 2)
                    }
                    historyView
                }.padding(24)
            }
            Divider().opacity(0.5)
            HStack(spacing: 7) {
                Image(systemName: "lock.shield").foregroundStyle(egressAccent)
                Text("只读检测 · 无登录 Cookie · 不修改代理、DNS 和 TUN")
                Spacer()
                if let date = model.lastCheck { Text(date.formatted(date: .omitted, time: .standard)) }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 11)
        }
        .frame(minWidth: 1040, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in model.history.prune() }
    }
    private var resultTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("请求路径").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: pathWidth, alignment: .leading).padding(.horizontal, 14)
                ForEach(EgressLocalDiagnostics.hosts, id: \.self) { host in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text("\(model.results[host]?.count ?? 0) / \(model.enabledKinds.count) 完成").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 12)
                }
            }.background(Color.primary.opacity(0.025))
            Divider().opacity(0.6)
            ForEach(EgressProbeKind.allCases) { kind in
                HStack(alignment: .center, spacing: 0) {
                    HStack(spacing: 9) {
                        Image(systemName: kind.symbol).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 17)
                        Text(kind.title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    }.help(kind.detail).frame(width: pathWidth, alignment: .leading).padding(.horizontal, 14)
                    ForEach(EgressLocalDiagnostics.hosts, id: \.self) { host in
                        EgressProbeCell(row: model.results[host]?[kind], previousIP: model.previousIPs[model.resultKey(host, kind)], pending: model.pending.contains(model.resultKey(host, kind)), changed: model.results[host]?[kind].map { model.changed($0, host: host) } ?? false, enabled: model.proxyEnabled || kind != .proxy)
                    }
                }
                if kind != .browser { Divider().opacity(0.5) }
            }
        }.background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09), lineWidth: 1))
    }
    private var historyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("IP 历史").font(.system(size: 13, weight: .semibold))
                Text("\(model.history.uniqueIPs.count) 个去重记录").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            if let warning = model.history.warning { Text(warning).font(.system(size: 11)).foregroundStyle(.orange) }
            if model.history.uniqueIPs.isEmpty {
                Text("成功检测后自动记录；失败不会覆盖上次成功的 IP。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            } else {
                VStack(spacing: 0) {
                    ForEach(model.history.uniqueIPs, id: \.self) { ip in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ip).font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                Text(model.history.isLatestIP(ip) ? "最新出口" : "24 小时内历史出口").font(.system(size: 10)).foregroundStyle(.secondary)
                            }.frame(width: 235, alignment: .leading)
                            Text(model.history.sources(ip)).font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(model.history.lastSeen(ip).formatted(date: .numeric, time: .shortened))
                                .font(.system(size: 10)).foregroundStyle(.secondary).help("最后检测到的时间")
                        }.padding(13)
                        if ip != model.history.uniqueIPs.last { Divider().opacity(0.5) }
                    }
                }.background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09), lineWidth: 1))
            }
            Text("每条路径保留最新 IP；被替代的记录在 24 小时后清理。历史仅保存在本机。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("节点检测").font(.system(size: 22, weight: .semibold))
                Text("Anthropic 出口环境").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.check) {
                Label(model.running ? "正在检测" : "开始检测", systemImage: model.running ? "hourglass" : "arrow.clockwise")
            }.buttonStyle(EgressPrimaryButtonStyle()).keyboardShortcut("r", modifiers: .command).disabled(model.running).opacity(model.running ? 0.65 : 1)
        }
    }
    private var controls: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("检测目标").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Anthropic API · Claude · 开发平台").font(.system(size: 12, weight: .medium))
                    .help(EgressLocalDiagnostics.hosts.joined(separator: " · "))
                Text("全部检测 /cdn-cgi/trace").font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("自定义代理", isOn: $model.proxyEnabled).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                if model.proxyEnabled {
                    TextField("http://代理地址:端口", text: $model.proxy).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 230)
                } else {
                    Text("仅用于此页出口检测").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 230, alignment: .leading)
                }
            }
            VStack(alignment: .trailing, spacing: 5) {
                Text("期望出口").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("美国 US").font(.system(size: 12, weight: .medium)).foregroundStyle(egressAccent)
            }.frame(width: 85, alignment: .trailing)
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07), lineWidth: 1)).disabled(model.running)
    }
}

struct EgressProbeCell: View {
    let row: EgressProbeResult?
    let previousIP: String?
    let pending: Bool
    let changed: Bool
    let enabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !enabled { Text("未启用").font(.system(size: 11)).foregroundStyle(.tertiary) }
            else if pending { ProgressView().controlSize(.small) }
            else if let row {
                if let error = row.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).help(error).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(previousIP.map { "\($0) → \(row.ip ?? "—")" } ?? row.ip ?? "—")
                        .foregroundStyle(previousIP == nil ? Color.primary : .orange)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(row.country == "US" ? "美国 US" : row.country ?? "未知").foregroundStyle(row.country == "US" ? .green : .orange)
                        Text("\(row.milliseconds) ms").foregroundStyle(.secondary)
                    }.font(.system(size: 10))
                    if changed { Text(previousIP == nil ? "基准变化" : "IP 已变更").font(.system(size: 10)).foregroundStyle(.orange) }
                }
                if row.attempts > 1 { Text(row.isSuccess ? "重试后成功" : "已重试 1 次").font(.system(size: 10)).foregroundStyle(.secondary) }
                if let count = row.cookiesAtStart { Text("临时会话 · Cookie：\(count)").font(.system(size: 10)).foregroundStyle(.secondary) }
            } else { Text("未检测").font(.system(size: 11)).foregroundStyle(.tertiary) }
        }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10).opacity(enabled ? 1 : 0.65)
    }
}
