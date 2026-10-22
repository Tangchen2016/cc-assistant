import SwiftUI

/// Live requests: the built-in proxy's own traffic, or (read-only) the user's Clash.
struct ConnectionsView: View {
    @ObservedObject var subscriptions: SubscriptionModel
    @ObservedObject var clash: ClashObserver
    @ObservedObject var egress: EgressCheckModel
    @AppStorage("connections.source") private var storedSource = "clash"
    private var source: String { LineEngine.enabled ? storedSource : "clash" }
    @AppStorage("connections.relevantOnly") private var relevantOnly = true
    @AppStorage("connections.includeClosed") private var includeClosed = true
    @State private var filter = ""

    private var rows: [LineEngine.Connection] {
        var rows = source == "clash" ? clash.connections : subscriptions.connections
        if source == "clash" && relevantOnly { let domains = clash.watchedDomains(); rows = rows.filter { ClashObserver.matches($0.host, domains) || ClaudeRules.covers($0.host) } }
        if includeClosed { rows += source == "clash" ? clash.closed : subscriptions.closedConnections }
        rows.sort { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
        return filter.isEmpty ? rows : rows.filter { $0.host.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if LineEngine.enabled {
                    Picker("来源", selection: $storedSource) {
                        Text("本机 Clash").tag("clash")
                        Text("内置代理").tag("engine")
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if source == "clash" { Toggle("仅相关域名", isOn: $relevantOnly).toggleStyle(.checkbox).controlSize(.small).help("Claude 域名与线路规则中的域名") }
                Toggle("含已结束", isOn: $includeClosed).toggleStyle(.checkbox).controlSize(.small).help("保留最近 30 分钟内结束的连接，便于溯源")
                Spacer()
                TextField("筛选域名", text: $filter).textFieldStyle(.roundedBorder).frame(width: 140).controlSize(.small)
                Button("日志…") { try? FileManager.default.createDirectory(at: TrafficLog.directory, withIntermediateDirectories: true); NSWorkspace.shared.open(TrafficLog.directory) }.controlSize(.small)
                    .help("按天保存最近 \(TrafficLog.retentionDays) 天：请求、连接摘要与核验记录，不含请求内容")
            }
            HStack(spacing: 8) {
                if source == "clash" {
                    Text(clash.status)
                    Button("立即检测出口") { egress.check() }.buttonStyle(.link).disabled(egress.running)
                        .help("运行「检测」页的完整出口检测（每 5 分钟及网络变化时自动运行），结果对应到连接的出口节点")
                } else if let exit = subscriptions.gateExit {
                    Text("出口 \(exit)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                Spacer()
                Text("进行中 \(rows.filter { $0.closedAt == nil }.count) · 共 \(rows.count)")
            }.font(.caption).foregroundStyle(.secondary)
            content
        }.frame(maxHeight: .infinity, alignment: .top).card(padding: 14)
    }

    @ViewBuilder private var content: some View {
        if source == "engine" && !subscriptions.lineRunning {
            Text("启动内置代理后，这里实时显示经它转发的请求。").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
        } else if source == "engine", case .blocked = subscriptions.gate {
            Label("已拦截：请求在本机被拒绝，不会建立连接。", systemImage: "xmark.shield").font(.callout).foregroundStyle(.red).padding(.vertical, 8)
        } else if source == "clash" && clash.controller == nil {
            Text("未找到本机 Clash 的控制接口。支持 Clash Party、Clash Verge 等基于 mihomo 的客户端。").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
        } else {
            Table(rows) {
                TableColumn("状态") { row in
                    if let closed = row.closedAt { Text("结束 " + closed.formatted(date: .omitted, time: .standard)).foregroundStyle(.tertiary) }
                    else { Label("进行中", systemImage: "circle.fill").labelStyle(StatusDotStyle()) }
                }.width(min: 70, ideal: 96)
                TableColumn("域名") { row in
                    Text(row.host).lineLimit(1).truncationMode(.head).textSelection(.enabled).help(row.host)
                }.width(min: 160, ideal: 280)
                TableColumn("出口 IP") { row in exitCell(row) }.width(min: 100, ideal: 120)
                TableColumn("链路") { Text($0.chain).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help($0.chain) }.width(min: 120, ideal: 190)
                TableColumn("规则") { Text($0.rule).lineLimit(1).foregroundStyle(.secondary).help($0.rule) }.width(min: 60, ideal: 90)
                TableColumn("流量") { row in Text("↑\(bytes(row.upload)) ↓\(bytes(row.download))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }.width(110)
                TableColumn("时长") { row in Text(row.start.map { since($0) } ?? "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }.width(50)
            }.frame(minHeight: 240, maxHeight: .infinity)
        }
    }
    @ViewBuilder private func exitCell(_ row: LineEngine.Connection) -> some View {
        if source == "engine" {
            Text(subscriptions.gateExit?.components(separatedBy: " · ").first ?? "—").font(.system(size: 11, design: .monospaced)).help("内置代理总闸最近一次核验到的出口")
        } else if clash.exitByNode[row.exitNode] == nil, !clash.exitByNode.isEmpty, ClaudeRules.covers(row.host) {
            // A Claude domain leaving through a node the exit check never used: it is not on the dedicated line.
            Label("未走专线", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                .help("此请求属于 Claude 推荐规则，却经「\(row.exitNode)」出去，不是已检测的专线出口。在线路中点「补全推荐规则」后重新发布。")
        } else if let exit = clash.exitByNode[row.exitNode] {
            Text(exit.ip).font(.system(size: 11, design: .monospaced)).foregroundStyle(clash.changedNodes.contains(row.exitNode) ? Color.red : Color.primary)
                .help("节点「\(row.exitNode)」的出口，\(exit.at.formatted(date: .omitted, time: .shortened)) 检测" + (clash.changedNodes.contains(row.exitNode) ? "；与上次检测不同" : ""))
        } else {
            Text("待检测").foregroundStyle(.tertiary).help("该节点尚未被出口检测覆盖；每 5 分钟自动检测，也可点「立即检测出口」")
        }
    }
    private func bytes(_ value: Int) -> String {
        let units = ["B", "K", "M", "G"]; var size = Double(value); var unit = 0
        while size >= 1024 && unit < units.count - 1 { size /= 1024; unit += 1 }
        return unit == 0 ? "\(value)B" : String(format: "%.1f%@", size, units[unit])
    }
    private func since(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h"
    }
}

private struct StatusDotStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 6)).foregroundStyle(.green); configuration.title }
    }
}
