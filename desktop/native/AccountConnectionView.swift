import SwiftUI

struct AccountConnectionView: View {
    @ObservedObject var model: AccountPoolModel
    @ObservedObject var flow: AccountConnectionFlow
    @State private var showDetails = false
    var browser: RegistrationModel?
    var browserResolver: ((String) throws -> RegistrationModel)? = nil
    var browserContextEmail: String? = nil
    private var browserMatchesAccount: Bool { browserContextEmail == nil || browserContextEmail == flow.expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private let accent = Theme.accent

    init(model: AccountPoolModel, browser: RegistrationModel?, browserResolver: ((String) throws -> RegistrationModel)? = nil, browserContextEmail: String? = nil) {
        self.model = model; flow = model.connectionFlow; self.browser = browser; self.browserResolver = browserResolver; self.browserContextEmail = browserContextEmail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 24)).foregroundStyle(accent)
                    .frame(width: 48, height: 48)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(flow.title).font(.system(size: 21, weight: .semibold))
                    Text("完成官网登录，核对身份后保存到号池。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(24)

            HStack(spacing: 12) {
                step("1", "准备账号", active: flow.candidate == nil && !flow.busy)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                step("2", "读取身份", active: flow.busy)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                step("3", "确认入库", active: flow.candidate != nil)
                Spacer(minLength: 0)
            }.padding(.horizontal, 24).padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if flow.browserAvailable {
                        Picker("接入方式", selection: $flow.source) {
                            ForEach(AccountConnectionSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(flow.intent == .register ? "注册邮箱" : "目标邮箱（选填）")
                            .font(.system(size: 12, weight: .medium))
                        TextField("name@example.com", text: $flow.expectedEmail)
                            .textFieldStyle(.roundedBorder).controlSize(.large)
                            .disabled(flow.targetID != nil).accessibilityLabel("目标账号邮箱")
                    }
                    if flow.source == .browser {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("在独立浏览器中完成登录", systemImage: "macwindow")
                                    .font(.system(size: 13, weight: .medium))
                                Text("完成后返回这里，点击「读取账号」。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button("打开官网", action: flow.openOfficialPage).controlSize(.large)
                        }.padding(16).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        if let browser, browserMatchesAccount { AccountBrowserActions(browser: browser) }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Session").font(.system(size: 12, weight: .medium))
                                Spacer()
                                Button("打开官网", action: flow.openOfficialPage).buttonStyle(.link)
                            }
                            SecureField("粘贴 sessionKey 值", text: $flow.sessionInput)
                                .textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel("Claude Session")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("日常 Chrome 已登录？可用插件复制 Session，再粘贴到这里。")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Link("安装 Claude Session Key 插件（第三方）", destination: URL(string: "https://chromewebstore.google.com/detail/claude-session-key/ppofmhjkjfinjpidlidepeonimpjmadj?hl=zh-CN")!)
                                    .font(.system(size: 12))
                                Text("安装前请核对插件权限。Session 是登录凭据，请勿公开或发送给他人。")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Toggle("保存到本机，方便下次刷新", isOn: $flow.rememberSession)
                                .font(.system(size: 12))
                            Text("本机文件保存，未加密；不写入系统钥匙串。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if flow.intent == .register { MailAssistantView(email: flow.expectedEmail, browser: browser, browserResolver: browserResolver) }
                    if !flow.message.isEmpty && flow.candidate == nil {
                        HStack(alignment: .top, spacing: 8) {
                            if flow.busy { ProgressView().controlSize(.small) }
                            else { Image(systemName: "info.circle").foregroundStyle(accent) }
                            Text(flow.message).font(.system(size: 12)).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let candidate = flow.candidate {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("已识别 · 请核对", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.system(size: 12, weight: .semibold))
                            Text(candidate.identity.email).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                            if let name = candidate.identity.name { Text(name).font(.system(size: 12)).foregroundStyle(.secondary) }
                            Text("套餐：\(candidate.identity.plan ?? "官网未明确返回")\(candidate.identity.planIsInferred ? "（按接口档位识别）" : "")")
                                .font(.system(size: 12))
                            Text(model.activeRecords.contains(where: { $0.email == candidate.identity.email })
                                 ? "将更新已有记录，保留备注、手动状态和到期日。"
                                 : "确认后加入号池，未返回的到期日可手动补充。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                    DisclosureGroup("连接与隐私说明", isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 10) {
                            if flow.source == .browser {
                                Text("沿用当前独立环境。如浏览器已打开，请先关闭，再从本页打开。会话由 Chrome 管理，cc助手只保存账号资料和环境关联；本机连接随浏览器退出而关闭。")
                                if let browser, browserMatchesAccount {
                                    AccountBrowserConnectionNotice(browser: browser)
                                    Button("关闭独立浏览器", action: browser.closeBrowser)
                                        .disabled(browser.browserRuntime.phase == .stopped)
                                }
                            } else {
                                Text("仅向 claude.ai 读取账号资料。Session 使用独立本地文件及用户权限保护，不包含在普通账号备份中。")
                            }
                        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.bottom, 20)
            }
            Divider()
            HStack(spacing: 10) {
                Text("仅读取资料，由你确认保存。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: model.cancelConnection).keyboardShortcut(.cancelAction)
                if flow.candidate != nil {
                    Button("重新读取", action: flow.read).disabled(flow.busy)
                }
                Button(flow.candidate == nil ? (flow.busy ? "正在读取…" : "读取账号") : "确认入库") {
                    if flow.candidate == nil { flow.read() } else { model.acceptConnection() }
                }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(flow.busy).keyboardShortcut(.defaultAction)
            }.controlSize(.large).padding(20)
        }.frame(width: 580, height: flow.candidate == nil ? 550 : 680)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func step(_ number: String, _ title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text(number).font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(active ? accent.opacity(0.12) : Color.secondary.opacity(0.08), in: Circle())
            Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
        }.foregroundStyle(active ? accent : .secondary)
    }
}

private struct AccountBrowserConnectionNotice: View {
    @ObservedObject var browser: RegistrationModel
    var body: some View {
        Text(browser.status).font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

private struct AccountBrowserActions: View {
    @ObservedObject var browser: RegistrationModel
    @State private var confirmingRestart = false
    @State private var reconnecting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !browser.status.isEmpty {
                Text(browser.status).font(.system(size: 12)).textSelection(.enabled)
            }
            HStack {
                if browser.openingBrowser || reconnecting { ProgressView().controlSize(.small) }
                Button("关闭并重新连接") { confirmingRestart = true }
                    .disabled(browser.openingBrowser || reconnecting)
                Text("保留登录资料").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .alert("重新连接独立浏览器？", isPresented: $confirmingRestart) {
            Button("取消", role: .cancel) {}
            Button("关闭并重新连接") {
                reconnecting = true
                Task { await browser.reconnectAccountBrowser(); reconnecting = false }
            }
        } message: {
            Text("将关闭此独立浏览器的窗口，并重新打开 Claude 官网。请先保存页面中未完成的操作，已有登录资料会保留。")
        }
    }
}
