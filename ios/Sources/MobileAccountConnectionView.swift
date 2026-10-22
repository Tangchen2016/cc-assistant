import SwiftUI

struct MobileAccountConnectionView: View {
    @ObservedObject var model: AccountPoolModel
    @ObservedObject var flow: AccountConnectionFlow
    init(model: AccountPoolModel) { self.model = model; flow = model.connectionFlow }
    var body: some View {
        NavigationStack {
            Form {
                Section(flow.intent == .register ? "注册新账号" : "已有账号") {
                    TextField(flow.intent == .register ? "准备注册的邮箱" : "目标邮箱（选填）", text: $flow.expectedEmail)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(flow.targetID != nil)
                    Button("打开 Claude 官网", action: flow.openOfficialPage)
                    Text("在官网完成注册或登录后返回。iOS 无法直接读取 Safari 会话，请使用自己的 sessionKey 接入。").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    SecureField("粘贴 sessionKey 值", text: $flow.sessionInput).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("在本机保留 Session", isOn: $flow.rememberSession)
                } header: { Text("Session 接入") } footer: {
                    Text("只向 claude.ai 读取资料。使用 App 私有文件保存，不存系统钥匙串，不包含在普通账号备份中。")
                }
                Section {
                    Button(action: flow.read) { HStack { Text("读取并识别账号"); Spacer(); if flow.busy { ProgressView() } } }.disabled(flow.busy)
                    if !flow.message.isEmpty { Text(flow.message).font(.footnote).foregroundStyle(.secondary) }
                }
                if let result = flow.candidate {
                    Section("核对账号") {
                        LabeledContent("邮箱", value: result.identity.email)
                        LabeledContent("套餐", value: result.identity.plan ?? "未明确返回")
                        if result.identity.planIsInferred { Text("套餐按接口档位识别，请核对。").font(.footnote).foregroundStyle(.secondary) }
                        Text("同邮箱会更新原记录，备注、手动状态和到期日保留。").font(.footnote).foregroundStyle(.secondary)
                        Button("确认入号池", action: model.acceptConnection)
                    }
                }
            }.navigationTitle(flow.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: model.cancelConnection) } }
                .interactiveDismissDisabled(flow.hasPendingInput)
        }.tint(MobileStyle.accent)
    }
}
