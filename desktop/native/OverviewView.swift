import SwiftUI

/// Home: is the line up, is the exit right, is the browser ready — each with its next action.
struct OverviewView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var subscriptions: SubscriptionModel
    @ObservedObject var egress: EgressCheckModel
    @ObservedObject var browsers: AccountBrowserLibrary
    @ObservedObject var accounts: AccountPoolModel
    @AppStorage("claudeLine.selectedRecord") private var lineID = ""

    var body: some View {
        Page(title: "概览", subtitle: LineEngine.enabled ? "内置代理、出口与浏览器的当前状态。" : "出口与浏览器的当前状态。") {
            if !LineEngine.enabled {
                Button(egress.running ? "检测中…" : "检测出口") { egress.check() }.disabled(egress.running)
            } else if subscriptions.lineRunning {
                Button("停止内置代理") { subscriptions.stopLine() }
            } else {
                Button("启动内置代理") { Task { await subscriptions.startLine(lineID) } }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(lineID.isEmpty)
            }
        } content: {
            HStack(alignment: .top, spacing: 12) {
                if LineEngine.enabled { lineTile }
                exitTile
                BrowserTile(model: browsers.active, open: { model.route = .browser })
            }
            Button { model.route = .accounts } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.2.crop.square.stack").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                    Text("账号").font(.system(size: 13, weight: .semibold))
                    Text("已记录 \(accounts.activeRecords.count) 个 · 7 天内到期 \(accounts.expiringSoonCount) 个")
                        .font(.callout).foregroundStyle(accounts.expiringSoonCount > 0 ? Color.orange : Color.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }.card(padding: 14).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    private var lineTile: some View {
        OverviewTile(title: "内置代理", symbol: "bolt.horizontal.circle") {
            StatusBadge(text: subscriptions.lineRunning ? "运行中" : "未启动", color: subscriptions.lineRunning ? .green : .secondary)
            Picker("线路", selection: $lineID) {
                Text("选择线路").tag("")
                ForEach(subscriptions.lineRecords) { record in Text(record.profile.name).tag(record.id) }
            }.labelsHidden().disabled(subscriptions.lineRunning)
            GateStatusView(subscriptions: subscriptions, egress: egress)
            Text(subscriptions.lineStatus.isEmpty ? "在本机运行所选线路；出口与标记 IP 一致才放行，否则在本机拦截。" : subscriptions.lineStatus)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } actions: {
            Button("管理线路…") { model.route = .lines }
        }
    }

    private var exitTile: some View {
        OverviewTile(title: "出口", symbol: "checkmark.shield") {
            StatusBadge(text: egress.summary, color: egress.summaryColor)
            Text(egress.exitIPs.first ?? "—").font(.system(size: 20, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(egress.successful.first?.country.map { "国家/地区 \($0)" + (egress.exitIPs.count > 1 ? " · 共 \(egress.exitIPs.count) 个 IP" : "") } ?? egress.status)
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button(egress.running ? "检测中…" : "重新检测") { egress.check() }.disabled(egress.running)
            Button("详情") { model.route = .detection }.buttonStyle(.borderless)
        }
    }
}

private struct BrowserTile: View {
    @ObservedObject var model: RegistrationModel
    let open: () -> Void
    var body: some View {
        OverviewTile(title: "浏览器", symbol: "macwindow") {
            StatusBadge(text: model.browserRuntime.phase.rawValue, color: model.browserRuntime.phase == .running ? .green : model.browserRuntime.phase == .stopped ? .secondary : .orange)
            Text(model.engineName).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text("代理 " + (model.settings.proxy.isEmpty ? "直连" : model.settings.proxy)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        } actions: {
            Button(model.openingBrowser ? "启动中…" : "打开并检测") { model.openBrowser(RegistrationModel.browserCheckPage) }
                .disabled(model.engine == nil || model.openingBrowser)
            Button("设置") { open() }.buttonStyle(.borderless)
        }
    }
}

private struct OverviewTile<Content: View, Actions: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
            Spacer(minLength: 0)
            HStack(spacing: 8) { actions() }
        }.frame(minHeight: 170, alignment: .topLeading).card(padding: 16)
    }
}
