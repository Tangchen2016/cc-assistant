import SwiftUI

enum MobileStyle {
    static let accent = Color(red: 171 / 255, green: 66 / 255, blue: 41 / 255)
    static let paper = Color(uiColor: .systemGroupedBackground)
}

@main struct CCAssistantApp: App {
    @StateObject private var accounts = AccountPoolModel()
    @StateObject private var egress = MobileEgressModel()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section {
                        HStack(spacing: 14) {
                            Image("BrandIcon").resizable().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("cc助手").font(.title2.weight(.semibold))
                                Text("把网络和账号，整理清楚。").font(.footnote).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 8)
                    }
                    Section("网络与环境") {
                        NavigationLink { MobileEgressView(model: egress) } label: { menu("环境检测", detail: "出口 IP · 时区 · 标记对比", symbol: "shield.lefthalf.filled") }
                    }
                    Section("账号管理") {
                        NavigationLink { MobileAccountPoolView(model: accounts) } label: { menu("号池管理", detail: "\(accounts.activeRecords.count) 个账号 · 状态与订阅", symbol: "person.2.crop.square.stack") }
                        NavigationLink { MobileAccountGuideView(accounts: accounts) } label: { menu("账号指南", detail: "注册准备 · 订阅 · 日常使用", symbol: "book.closed") }
                    }
                    Section("应用设置") {
                        NavigationLink { MobileSettingsView(model: accounts) } label: { menu("设置与备份", detail: "本地资料 · 文件导入导出", symbol: "gearshape") }
                    }
                    Section { Text("资料仅保存在此 iPhone，不会自动登录账号或与 Mac 同步。").font(.footnote).foregroundStyle(.secondary) }
                }.scrollContentBackground(.hidden).background(MobileStyle.paper).navigationTitle("功能")
            }.tint(MobileStyle.accent)
            .onAppear { accounts.connectionFlow.openBrowser = { _ in UIApplication.shared.open(URL(string: "https://claude.ai/")!) } }
            .sheet(isPresented: $accounts.showConnection, onDismiss: { accounts.connectionFlow.cancel() }) { MobileAccountConnectionView(model: accounts) }
        }
    }
    private func menu(_ title: String, detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 5)
        } icon: { Image(systemName: symbol).foregroundStyle(MobileStyle.accent).frame(width: 24) }
    }
}

struct MobileAccountGuideView: View {
    @ObservedObject var accounts: AccountPoolModel
    var body: some View {
        List {
            Section("注册准备") {
                Text("先确认网络出口，在官网完成注册后返回，识别邮箱并加入号池。")
                Button("注册新账号并入库") { accounts.beginConnection(.register) }
                Button("接入已有账号") { accounts.beginConnection(.existing) }
            }
            Section("订阅与使用") { Text("套餐可通过接入识别，未返回的到期日可手动记录；付款和套餐管理请在官方页面完成。") }
            Section("保留现有会话") { Text("继续使用原来的浏览器资料和登录状态。切换浏览器或新建资料目录可能建立新会话，是否识别为新设备由服务方判断。") }
            Section("检测范围") { Text("原生检测仅反映此 App 的请求出口，不代表 Safari、小火箭配置或登录后的服务可用性。") }
        }.navigationTitle("账号指南")
    }
}
