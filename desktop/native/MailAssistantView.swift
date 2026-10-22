import SwiftUI
import AppKit

struct MailAssistantView: View {
    let email: String
    var browser: RegistrationModel? = nil
    var browserResolver: ((String) throws -> RegistrationModel)? = nil
    @State private var openError = ""
    @StateObject private var model = MailAssistantModel()
    @State private var configuring = false
    @State private var openingLocal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("邮件辅助", systemImage: "envelope.badge").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("连接设置") { configuring.toggle() }.buttonStyle(.link)
            }
            if configuring {
                TextField("Email Worker 地址（https://…）", text: $model.settings.endpoint)
                SecureField("邮件辅助访问密钥", text: $model.settings.token)
                HStack {
                    Text("仅存本机文件，不进钥匙串或号池备份。").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存") { model.save() }
                }
            }
            HStack {
                if model.waiting { ProgressView().controlSize(.small) }
                Text(model.settings.endpoint.isEmpty ? "首次使用请配置邮件服务连接。" : model.status).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if model.waiting {
                    Button("停止", action: model.stop)
                } else {
                    Button("等待登录邮件") { model.start(email: email) }.disabled(model.settings.endpoint.isEmpty || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Button(openingLocal ? "正在打开本地邮件页…" : "在账号浏览器打开邮件页") {
                openingLocal = true
                Task {
                    defer { openingLocal = false }
                    do {
                        let target = try browserResolver?(email) ?? browser
                        guard let target else { throw SubscriptionFailure("请先选择账号的独立浏览器。") }
                        if !model.waiting && model.loginURL == nil && model.code == nil { model.start(email: email) }
                        let page = try await model.localPage.open(model: model, email: email)
                        target.openBrowser(page.absoluteString, accountLink: true)
                        openError = ""
                    } catch { openError = error.localizedDescription }
                }
            }.disabled(openingLocal || model.settings.endpoint.isEmpty || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let link = model.loginURL {
                HStack {
                    Label("Claude 官方登录链接", systemImage: "link")
                    Spacer()
                    Button("在独立浏览器打开") {
                        guard let checked = ClaudeMailLink.validated(link.absoluteString, email: email) else { return }
                        do {
                            let target = try browserResolver?(email) ?? browser
                            target?.openBrowser(checked.absoluteString, accountLink: true)
                            openError = ""
                        } catch { openError = error.localizedDescription }
                    }.disabled(browser == nil)
                }.font(.system(size: 12))
            }
            if !openError.isEmpty { Text(openError).font(.footnote).foregroundStyle(.orange) }
            if let code = model.code {
                HStack {
                    Text(code).font(.system(size: 24, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("复制验证码") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                }
            }
        }.textFieldStyle(.roundedBorder).padding(16)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: email) { _, _ in model.stop() }
            .onDisappear { model.stop() }
    }
}
