import SwiftUI

struct ShadowrocketRouteForm: View {
    @ObservedObject var model: SubscriptionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text("固定出口").font(.headline)
                TextField("线路名称", text: $model.profile.name)
                StaticNodeAssociation(model: model, group: 0)
                Text("无需填写源订阅；静态出口在“静态IP节点”中统一管理。").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("用 AI 部署静态代理") { model.showGuide = true }
            }.textFieldStyle(.roundedBorder)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("只扩展 Claude").font(.headline)
                Text("anthropic.com · claude.ai · claude.com").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Text("生成一个固定出口节点和 Claude 规则模块，保留手机现有网站分流。需要链式代理时，导入后在该节点的“代理通过”中选择已有普通节点。").font(.system(size: 13))
                Text("发布后手机可独立下载，Mac 无需保持在线。静态代理凭据会保存到你的远程订阅服务，请勿公开分享导入链接。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack { Button("取消", action: model.list); Spacer(); Button(model.currentId == nil ? "保存并生成手机地址" : "保存并更新手机地址", action: model.save).buttonStyle(.borderedProminent).tint(Theme.accent).disabled(model.profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.profile.groups.first?.staticNodeId == nil) }
        }.card(padding: 24)
    }
}

struct ShadowrocketRouteOutput: View {
    @ObservedObject var model: SubscriptionModel
    let record: SubscriptionRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(record.remote == nil ? "已保存，待发布" : "手机线路已生成", systemImage: record.remote == nil ? "cloud" : "checkmark.circle").font(.title2)
            Text(record.profile.name).font(.headline)
            if let remote = record.remote {
                HStack {
                    Button { model.qrMode = .nodes; model.qrRecord = record } label: { Label("小火箭扫码添加节点", systemImage: "qrcode") }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    Button("规则安装向导") { model.qrMode = .guide; model.qrRecord = record }
                }
                HStack {
                    Button("复制节点地址") { if let url = SubscriptionMobileImport.exportURL(address: remote.subscriptionUrl, format: "shadowrocket-nodes") { model.copy(url) } }
                    Button("复制规则模块地址") { if let url = SubscriptionMobileImport.exportURL(address: remote.subscriptionUrl, format: "shadowrocket-module") { model.copy(url) } }
                    Button("同步更新", action: model.syncRemote)
                }
                if remote.lastError != nil { Text("远程同步失败，请重试。手机暂时仍使用上次发布的配置。").foregroundStyle(.orange) }
                Divider()
                Text("手机设置").font(.headline)
                Text("1. 用小火箭扫一扫添加专用节点。\n2. 需要链式代理时：点固定出口右侧 ⓘ → 代理通过 → 选择原订阅中的普通节点。不要选择固定出口自身。\n3. 用系统相机扫规则安装向导，安装并启用 Claude 模块。\n4. 日常继续选择原订阅节点，全局路由选“配置”，连接后检测 Claude 出口。").font(.system(size: 13)).lineSpacing(5)
                Text("未设置“代理通过”时，固定出口节点会直接连接；首页选择普通节点不会自动作为它的前置。").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("停用手机订阅", action: model.stopRemote).foregroundStyle(.secondary)
            } else {
                Text("发布成功后才能在手机上下载节点和规则。无需提供 Clash 订阅。").font(.system(size: 13)).foregroundStyle(.secondary)
                Button("发布手机线路", action: model.syncRemote).buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            HStack { Button("编辑") { model.open(record) }; Spacer(); Button("完成，返回列表", action: model.list) }
        }.card(padding: 24)
    }
}
