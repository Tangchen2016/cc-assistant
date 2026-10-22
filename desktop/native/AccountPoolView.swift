import SwiftUI
import AppKit

struct AccountPoolView: View {
    @ObservedObject var model: AccountPoolModel
    @State private var detailRecord: AccountPoolRecord?
    var browser: RegistrationModel? = nil
    var browserLibrary: AccountBrowserLibrary? = nil
    var onBrowserSettings: (() -> Void)? = nil
    private let accent = Theme.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let error = model.store.loadError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 13))
                Button("打开数据目录") { NSWorkspace.shared.open(model.store.fileURL.deletingLastPathComponent()) }
            }
            controls
            if model.visibleRecords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.crop.square.stack").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(model.showDeleted ? "回收站中没有匹配的账号" : model.activeRecords.isEmpty ? "还没有记录账号" : "没有匹配的账号").font(.system(size: 17, weight: .semibold))
                    Text(model.showDeleted ? "删除的记录可以在这里还原。" : "点击新增账号，记录邮箱、状态和订阅信息。").font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { accountsTable }
            HStack {
                Text(model.notice.isEmpty ? "资料本机保存。已关联账号可刷新信息，读取失败时保留原记录。" : model.notice)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 20)
            .frame(maxWidth: 1280).frame(maxWidth: .infinity).background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $detailRecord) { row in AccountBasicDetailsView(model: model, accountID: row.id) }
            .sheet(isPresented: $model.showEditor) { AccountPoolEditor(model: model) }
            .sheet(isPresented: $model.showBatch, onDismiss: model.cancelBatch) { AccountBatchImportView(model: model) }
            .sheet(isPresented: $model.showConnection, onDismiss: { model.connectionFlow.cancel() }) {
                if let library = browserLibrary { AccountBrowserConnectionHost(library: library, model: model) }
                else { AccountConnectionView(model: model, browser: browser) }
            }
    }
    private var header: some View {
        PageHeader(title: model.showDeleted ? "回收站" : "号池", subtitle: "记录已创建的账号，集中查看使用状态和订阅到期日。") {
            if !model.showDeleted {
                Button { model.refreshAll() } label: { Label("刷新全部", systemImage: "arrow.clockwise") }
                    .disabled(model.refreshableRecords.isEmpty || !model.refreshing.isEmpty).help("刷新所有已关联账号的资料和额度")
            }
            Button(model.showDeleted ? "返回号池" : "回收站（\(model.deletedCount)）") { model.showDeleted.toggle() }
            if !model.showDeleted {
                Menu {
                    Button("注册新账号并入库") { model.beginConnection(.register) }
                    Button("接入已有账号") { model.beginConnection(.existing) }
                    Button("批量导入 Session…", action: model.beginBatch)
                    Divider()
                    Button("手动记录账号", action: model.create)
                } label: { Label("新增账号", systemImage: "plus") }
                    .fixedSize().disabled(model.store.loadError != nil)
            }
        }
    }
    private var controls: some View {
        HStack(spacing: 12) {
            if !model.showDeleted && !model.activeRecords.isEmpty { summary }
            Spacer(minLength: 8)
            TextField("搜索邮箱、备注或套餐", text: $model.query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索账号").frame(width: 220)
        }
    }
    private var accountsTable: some View {
        VStack(spacing: 0) {
            AccountColumns(Text("账号"), Text("额度"), Text("浏览器环境"), Text("到期"), Text("状态"), Text("")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.visibleRecords) { row in accountRow(row) }
                }.padding(.bottom, 4)
            }
        }
    }
    private func accountRow(_ row: AccountPoolRecord) -> some View {
        AccountColumns(
            VStack(alignment: .leading, spacing: 5) {
                Button { detailRecord = row } label: {
                    Text(row.label.isEmpty ? row.email : row.label).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain).help("查看账号详情")
                HStack(spacing: 6) {
                    if !row.subscription.isEmpty { planPill(row) }
                    if !row.label.isEmpty { Text(row.email).lineLimit(1) }
                    Text(connectionLine(row)).lineLimit(1).help(model.connectionText(row))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            },
            quota(row),
            Group {
                if let library = browserLibrary { EnvironmentCell(library: library, row: row, connections: model.connections) }
                else { Text("—").foregroundStyle(.tertiary) }
            },
            expiry(row.expiresAt),
            statusPill(row),
            actions(row)
        )
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(row.sessionInvalidFrom != nil ? Color.red.opacity(0.45) : Color(nsColor: .separatorColor), lineWidth: row.sessionInvalidFrom != nil ? 1 : 0.5))
        .opacity(row.status == .disabled ? 0.6 : 1)
        .contextMenu { menuItems(row) }
    }
    private func planPill(_ row: AccountPoolRecord) -> some View {
        let inferred = row.identity?.planIsInferred == true && row.identity?.plan == row.subscription
        let paid = !["Free", ""].contains(row.subscription)
        return Text(row.subscription + (inferred ? " · 推断" : "")).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(paid ? accent : Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((paid ? accent : Color.secondary).opacity(0.12), in: Capsule())
            .help(inferred ? "按账号接口的组织与额度档位推断，不代表已核实订阅有效期。" : "套餐")
    }
    @ViewBuilder private func quota(_ row: AccountPoolRecord) -> some View {
        if row.sessionInvalidFrom != nil {
            Label("Session 失效，请重新接入", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
        } else if let usage = row.identity?.usage {
            VStack(alignment: .leading, spacing: 6) {
                UsageBar(title: "5h", window: usage.fiveHour)
                UsageBar(title: "7d", window: usage.sevenDay)
                if !usage.sortedModels.isEmpty {
                    Text(usage.sortedModels.map { "\($0.name) \(Int($0.window.percent.rounded()))%" }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.trailing, 12)
        } else {
            Text(row.identity?.plan == "Free" ? "Free 套餐无 5h / 7d 额度" : model.connections.exists(row.id) ? "尚未读取，点右上角刷新" : "未关联，无法读取")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
    private func statusPill(_ row: AccountPoolRecord) -> some View {
        let tone: Color = switch row.status { case .inUse: .green; case .available: .blue; case .attention: .orange; case .disabled: .secondary }
        return HStack(spacing: 5) {
            Circle().fill(tone).frame(width: 6, height: 6)
            Text(row.status.rawValue)
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(row.status == .disabled ? Color.secondary : .primary)
            .padding(.horizontal, 8).padding(.vertical, 3).background(tone.opacity(0.1), in: Capsule())
            .help(row.sessionInvalidFrom.map { "刷新时官网返回 401；重新接入成功后恢复为「\($0.rawValue)」。" } ?? row.status.rawValue)
    }
    @ViewBuilder private func actions(_ row: AccountPoolRecord) -> some View {
        if model.showDeleted {
            Button("还原") { model.restore(row) }.controlSize(.small)
        } else {
            HStack(spacing: 4) {
                if let library = browserLibrary { BrowserToggle(library: library, row: row, connections: model.connections) { openBrowser(row, library, page: "https://claude.ai/") } }
                HoverIconButton(symbol: "arrow.clockwise", help: "刷新账号资料和额度", busy: model.refreshing.contains(row.id)) { model.refresh(row) }
                    .disabled(model.refreshing.contains(row.id) || !model.connections.exists(row.id))
                Menu { menuItems(row) } label: { HoverIconLabel(symbol: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多操作").accessibilityLabel("更多账号操作")
            }
        }
    }
    @ViewBuilder private func menuItems(_ row: AccountPoolRecord) -> some View {
        if model.showDeleted {
            Button("还原") { model.restore(row) }
        } else {
            Button("编辑") { model.edit(row) }
            Button("账号详情") { detailRecord = row }
            if let library = browserLibrary {
                Button("打开浏览器并检测出口") { openBrowser(row, library, page: RegistrationModel.browserCheckPage) }
                Button("浏览器环境设置") {
                    do { try library.select(row.email); onBrowserSettings?() }
                    catch { model.reportEnvironmentError(error) }
                }
            }
            Divider()
            Button("接入 / 重新关联") { model.beginConnection(.existing, row: row) }
            Button("解除本机关联") { model.disconnect(row) }.disabled(!model.connections.exists(row.id))
            Divider()
            Button("复制邮箱") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.email, forType: .string) }
            Button("移到回收站", role: .destructive) { model.delete(row) }
        }
    }
    private func openBrowser(_ row: AccountPoolRecord, _ library: AccountBrowserLibrary, page: String) {
        do {
            let browser = try library.browser(for: row, connections: model.connections)
            try library.select(row.email)
            browser.openBrowser(page, accountLink: page != RegistrationModel.browserCheckPage)
        } catch { model.reportEnvironmentError(error) }
    }
    /// "Session · 3 分钟前" — the detail stays in the tooltip.
    private func connectionLine(_ row: AccountPoolRecord) -> String {
        guard model.connections.exists(row.id) else { return row.identity == nil ? "未关联" : "未关联本机" }
        let kind = model.connectionText(row).contains("浏览器") ? "浏览器" : "Session"
        return row.identity.map { kind + " · " + $0.checkedAt.formatted(.relative(presentation: .named)) + "更新" } ?? kind
    }
    private var summary: some View {
        let rows = model.activeRecords
        return HStack(spacing: 10) {
            chip("全部", "\(rows.count)", .primary, selected: model.filter == nil) { model.filter = nil }
            chip("使用中", "\(rows.filter { $0.status == .inUse }.count)", .primary, selected: model.filter == .inUse) { model.filter = .inUse }
            chip("备用", "\(rows.filter { $0.status == .available }.count)", .primary, selected: model.filter == .available) { model.filter = .available }
            chip("需处理", "\(rows.filter { $0.status == .attention }.count)", .orange, selected: model.filter == .attention) { model.filter = .attention }
            Divider().frame(height: 26)
            metric("接近限额", model.nearLimitCount, .orange)
            metric("Session 失效", model.invalidSessionCount, .red)
            metric("7 天内到期", model.expiringSoonCount, .orange)
        }
    }
    private func chip(_ title: String, _ value: String, _ tone: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                Text(value).fontWeight(.semibold).foregroundStyle(value == "0" ? Color.secondary : tone)
            }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? accent.opacity(0.12) : Color.primary.opacity(0.04), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? accent.opacity(0.5) : .clear))
                .contentShape(Capsule())
        }.buttonStyle(.plain).help("按状态筛选")
    }
    private func metric(_ title: String, _ count: Int, _ tone: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(count > 0 ? tone : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            Text("\(title) \(count)").font(.system(size: 12)).foregroundStyle(count > 0 ? .primary : .secondary)
        }
    }
    @ViewBuilder private func expiry(_ date: Date?) -> some View {
        if let date {
            let days = AccountPoolModel.daysUntilExpiry(date)
            VStack(alignment: .leading, spacing: 3) {
                Text(date.formatted(date: .numeric, time: .omitted)).font(.system(size: 11))
                if days <= 7 {
                    Text(days < 0 ? "已到期" : days == 0 ? "今日到期" : "\(days) 天后到期").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        } else { Text("—").font(.system(size: 11)).foregroundStyle(.tertiary).help("未记录到期日，可在编辑中填写") }
    }
}

private struct AccountPoolEditor: View {
    @ObservedObject var model: AccountPoolModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.editorTitle).font(.system(size: 21, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    field("账号邮箱", text: $model.draft.email, placeholder: "name@example.com")
                    field("备注名", text: $model.draft.label, placeholder: "便于识别的名称（可选）")
                    HStack {
                        Text("账号状态").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Picker("账号状态", selection: $model.draft.status) {
                            ForEach(AccountPoolStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 150)
                    }
                    field("订阅类型", text: $model.draft.subscription, placeholder: "填写账号的套餐名称（可选）")
                    Toggle("记录订阅到期日", isOn: Binding(get: { model.draft.expiresAt != nil }, set: { model.draft.expiresAt = $0 ? Date() : nil }))
                    if model.draft.expiresAt != nil {
                        DatePicker("订阅到期日", selection: Binding(get: { model.draft.expiresAt ?? Date() }, set: { model.draft.expiresAt = $0 }), displayedComponents: .date)
                    }
                    DatePicker("记录日期（手动）", selection: $model.draft.createdAt, displayedComponents: [.date, .hourAndMinute])
                    VStack(alignment: .leading, spacing: 7) {
                        Text("备注").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextEditor(text: $model.draft.notes).font(.system(size: 13)).frame(height: 85)
                            .padding(5).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                            .accessibilityLabel("账号备注")
                    }
                }.padding(.trailing, 6)
            }
            if !model.editorError.isEmpty { Text(model.editorError).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Text("本机记录，不执行账号登录或认证。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("保存账号", action: model.save).buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 535, height: 615)
    }
    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
}

/// Paste many sessionKeys, read them (capped concurrency), review, then save all at once.
private struct AccountBatchImportView: View {
    @ObservedObject var model: AccountPoolModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("批量导入 Session").font(.system(size: 21, weight: .semibold))
            Text("每行一个 sessionKey，读取后核对再统一入库。按当前浏览器代理读取，同时最多 \(AccountPoolModel.refreshConcurrency) 个。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if model.batchItems.isEmpty {
                TextEditor(text: $model.batchInput).font(.system(size: 12, design: .monospaced))
                    .padding(5).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    .accessibilityLabel("sessionKey 列表")
            } else {
                List(model.batchItems) { item in
                    HStack(spacing: 8) {
                        switch item.state {
                        case .reading:
                            ProgressView().controlSize(.small); Text("读取中…").foregroundStyle(.secondary)
                        case .ready(let reading):
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(reading.identity.email).textSelection(.enabled)
                            Spacer()
                            Text(reading.identity.plan ?? "套餐未知").foregroundStyle(.secondary)
                            if model.activeRecords.contains(where: { $0.email == reading.identity.email }) { Text("更新已有").foregroundStyle(.secondary) }
                        case .saved(let email):
                            Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.secondary); Text("\(email) 已入库").foregroundStyle(.secondary)
                        case .failed(let message):
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red); Text(message).foregroundStyle(.red).lineLimit(2)
                        }
                    }.font(.system(size: 12))
                }
            }
            Text("Session 是登录凭据，保存为本机文件（未加密），不写入系统钥匙串。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                if !model.batchItems.isEmpty && !model.batchBusy { Button("重新粘贴") { model.beginBatch() } }
                Spacer()
                Button("取消", action: model.cancelBatch).keyboardShortcut(.cancelAction)
                if model.batchItems.isEmpty || model.batchBusy {
                    Button(model.batchBusy ? "正在读取…" : "读取") { model.readBatch() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
                        .disabled(model.batchBusy || model.batchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("全部入库（\(model.batchReadyCount)）", action: model.saveBatch)
                        .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction).disabled(model.batchReadyCount == 0)
                }
            }.controlSize(.large)
        }.padding(26).frame(width: 560, height: 520)
    }
}

/// Proxy, time zone and last seen exit of the account's own browser environment.
private struct EnvironmentCell: View {
    @ObservedObject var library: AccountBrowserLibrary
    let row: AccountPoolRecord
    let connections: AccountConnectionStore
    var body: some View {
        if let preview = library.preview(for: row, connections: connections) {
            if let model = preview.model { EnvironmentSummary(model: model) } else { EnvironmentSummary.text(preview.settings, running: false, exit: nil) }
        } else {
            Text("未配置").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}
private struct EnvironmentSummary: View {
    @ObservedObject var model: RegistrationModel
    var body: some View {
        Self.text(model.settings, running: model.browserRuntime.pid != nil, exit: model.exitTimeZone, phase: model.browserRuntime.phase)
    }
    static func text(_ settings: RegistrationSettings, running: Bool, exit: BrowserExitTimeZone?, phase: BrowserRunPhase = .stopped) -> some View {
        let proxy = settings.proxy.isEmpty ? "直连" : (URL(string: settings.proxy)?.port.map { "代理 :\($0)" } ?? "代理")
        let zone = settings.timeZone.map { $0.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? $0 } ?? "系统时区"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(running ? (phase == .running ? Color.green : .orange) : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                Text(running ? phase.rawValue : "未打开").foregroundStyle(running ? .primary : .secondary).lineLimit(1)
            }
            Text("\(proxy) · \(zone)").foregroundStyle(.secondary).lineLimit(1)
            if let exit { Text(exit.ip).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1) }
        }.font(.system(size: 11))
            .help("代理 \(settings.proxy.isEmpty ? "直连" : settings.proxy)\n时区 \(settings.timeZone ?? "跟随系统")" + (exit.map { "\n出口 \($0.ip) · \($0.location)" } ?? "\n出口尚未检测"))
    }
}

/// Fixed column widths shared by the header and every account row; the account column flexes.
private struct AccountColumns<A: View, B: View, C: View, D: View, E: View, F: View>: View {
    let a: A, b: B, c: C, d: D, e: E, f: F
    init(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F) { self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            a.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            b.frame(width: 250, alignment: .leading)
            c.frame(width: 140, alignment: .leading)
            d.frame(width: 64, alignment: .leading)
            e.frame(width: 76, alignment: .leading)
            f.frame(width: 160, alignment: .trailing)
        }
    }
}

/// Small icon with a rounded hover background, so it reads as a button.
private struct HoverIconLabel: View {
    let symbol: String
    var busy = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Group {
            if busy { ProgressView().controlSize(.mini) } else { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
        }.frame(width: 26, height: 24).foregroundStyle(enabled ? Color.primary.opacity(hovering ? 0.9 : 0.6) : Color.secondary.opacity(0.4))
            .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle()).onHover { hovering = $0 }
    }
}
private struct HoverIconButton: View {
    let symbol: String, help: String
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { HoverIconLabel(symbol: symbol, busy: busy) }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

/// Open → "打开 Claude" (checks the exit first); running → "关闭浏览器".
private struct BrowserToggle: View {
    @ObservedObject var library: AccountBrowserLibrary
    let row: AccountPoolRecord, connections: AccountConnectionStore
    let open: () -> Void
    var body: some View {
        if let model = library.preview(for: row, connections: connections)?.model { Running(model: model, open: open) }
        else { Button("打开 Claude", action: open).controlSize(.small).help("先检测出口，通过后用此账号的独立浏览器打开 claude.ai") }
    }
    private struct Running: View {
        @ObservedObject var model: RegistrationModel
        let open: () -> Void
        var body: some View {
            Group { content }.tracksBrowser(model)
        }
        @ViewBuilder private var content: some View {
            if model.openingBrowser { Button("启动中…") {}.controlSize(.small).disabled(true) }
            else if model.browserRuntime.phase == .stopping { Button("关闭中…") {}.controlSize(.small).disabled(true) }
            else if model.browserRuntime.pid != nil {
                HStack(spacing: 6) {
                    Button("打开", action: model.showBrowser).controlSize(.small).help("切换到此账号已打开的浏览器")
                    Button("关闭", action: model.closeBrowser).controlSize(.small).help("关闭此账号的独立浏览器，登录资料保留")
                }
            } else { Button("打开 Claude", action: open).controlSize(.small).help("先检测出口，通过后用此账号的独立浏览器打开 claude.ai") }
        }
    }
}
extension View {
    /// Re-reads this environment's browser process while the row is on screen (the global monitor only follows the active one).
    // ponytail: 2 s poll per visible row; fine for a handful of accounts, switch to one shared ticker if the pool gets large
    func tracksBrowser(_ model: RegistrationModel) -> some View {
        task(id: ObjectIdentifier(model)) {
            while !Task.isCancelled {
                model.refreshBrowserState()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
