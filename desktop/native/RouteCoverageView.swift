import SwiftUI

/// Every recommended Claude domain: which Clash node carried it, and whether that is the dedicated exit.
struct RouteCoverageView: View {
    @ObservedObject var clash: ClashObserver
    @ObservedObject var egress: EgressCheckModel
    /// The dedicated exit: the single IP the main check saw, else the marked IP.
    private var expected: String? { egress.exitIPs.count == 1 ? egress.exitIPs.first : egress.markedIP }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("域名分流核验").font(.system(size: 13, weight: .semibold))
                Text(summary).font(.system(size: 11)).foregroundStyle(offLine > 0 ? Color.orange : Color.secondary)
                Spacer()
                if let at = clash.coverageAt { Text(at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary) }
                Button(clash.checkingCoverage ? "核验中…" : "重新核验") { Task { await clash.checkCoverage() } }
                    .controlSize(.small).disabled(clash.checkingCoverage || clash.controller == nil)
                    .help("逐个访问推荐规则中的域名，查看它们经本机 Clash 走了哪个节点")
            }
            if clash.controller == nil {
                Text("未检测到本机 Clash 控制接口，无法核验分流。").font(.callout).foregroundStyle(.secondary)
            } else if clash.coverage.isEmpty {
                Text("完整检测结束后自动核验；也可点「重新核验」。").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("域名"); Text("用途"); Text("出口"); Text("状态")
                    }.font(.caption).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(clash.coverage) { row in
                        GridRow {
                            Text(row.id).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Text(row.purpose).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(exit(row) ?? "—").font(.system(size: 12, design: .monospaced)).help(row.node.map { "经节点「\($0)」" } ?? "")
                            status(row)
                        }
                    }
                }
                Text("带出口的域名由网站直接返回所见 IP（Cloudflare）；其余按承载节点推断。未走专线时，在线路中点「补全推荐规则」，并在 Clash 中刷新订阅。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.card(padding: 16)
    }

    private func exit(_ row: ClashObserver.RouteCheck) -> String? { row.traceIP ?? row.node.flatMap { clash.exitByNode[$0]?.ip } }
    private func onLine(_ row: ClashObserver.RouteCheck) -> Bool? {
        guard let ip = exit(row) else { return row.node == nil ? nil : false }  // carried by an unchecked node = off the line
        return expected.map { $0 == ip }
    }
    private var offLine: Int { clash.coverage.filter { onLine($0) == false }.count }
    private var summary: String {
        guard !clash.coverage.isEmpty else { return "" }
        let ok = clash.coverage.filter { onLine($0) == true }.count
        return offLine > 0 ? "\(offLine) 个域名未走专线" : "\(ok)/\(clash.coverage.count) 走专线"
    }
    @ViewBuilder private func status(_ row: ClashObserver.RouteCheck) -> some View {
        switch onLine(row) {
        case true?: Label("走专线", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case false?: Label("未走专线" + (row.node.map { " · \($0)" } ?? ""), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
        case nil: Label(row.failed ? "请求失败" : "未观察到", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}
