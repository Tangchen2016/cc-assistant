import SwiftUI

struct MobileAccountPoolView: View {
    @ObservedObject var model: AccountPoolModel
    var body: some View {
        List {
            if let error = model.store.loadError { Section { Text(error).foregroundStyle(.orange) } }
            Section {
                HStack { Text(model.showDeleted ? "回收站" : "已记录 \(model.activeRecords.count) 个账号"); Spacer(); Text("\(model.visibleRecords.count) 条").foregroundStyle(.secondary) }
                Picker("账号状态", selection: $model.filter) {
                    Text("全部状态").tag(AccountPoolStatus?.none)
                    ForEach(AccountPoolStatus.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                if !model.showDeleted { Text("7 天内到期 \(model.expiringSoonCount) 个").font(.footnote).foregroundStyle(.secondary) }
            }
            if model.visibleRecords.isEmpty {
                ContentUnavailableView(model.showDeleted ? "回收站为空" : model.activeRecords.isEmpty ? "还没有记录账号" : "没有匹配的账号", systemImage: "person.2", description: Text("记录邮箱、订阅与到期日，无需重新登录。"))
            } else {
                ForEach(model.visibleRecords) { row in
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.label.isEmpty ? row.email : row.label).font(.headline)
                                    if !row.label.isEmpty { Text(row.email).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                                }
                                Spacer(minLength: 8)
                                Text(row.status.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(alignment: .top) {
                                info("订阅", row.subscription.isEmpty ? "未记录" : row.subscription)
                                Spacer()
                                VStack(alignment: .leading, spacing: 4) {
                                    info("到期日", row.expiresAt?.formatted(date: .numeric, time: .omitted) ?? "未记录")
                                    if let date = row.expiresAt {
                                        let days = AccountPoolModel.daysUntilExpiry(date)
                                        if days <= 7 { Text(days < 0 ? "已到期" : days == 0 ? "今日到期" : "\(days) 天后到期").font(.caption).foregroundStyle(.orange) }
                                    }
                                }
                            }
                            Text("创建于 \(row.createdAt.formatted(date: .numeric, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                            Text(model.connectionText(row)).font(.caption).foregroundStyle(.secondary)
                            if !row.notes.isEmpty { DisclosureGroup("备注") { Text(row.notes).font(.footnote).textSelection(.enabled) }.font(.footnote) }
                            if model.showDeleted { Button("还原账号") { model.restore(row) } }
                            else {
                                HStack {
                                    Button("编辑账号") { model.edit(row) }
                                    Spacer()
                                    Menu("账号操作") {
                                        Button("接入 / 重新关联") { model.beginConnection(.existing, row: row) }
                                        Button("刷新账号信息") { model.refresh(row) }.disabled(model.refreshing.contains(row.id) || !model.connections.exists(row.id))
                                        Button("解除本机关联") { model.disconnect(row) }.disabled(!model.connections.exists(row.id))
                                    }
                                }
                            }
                        }.padding(.vertical, 6)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !model.showDeleted { Button("移入回收站", role: .destructive) { model.delete(row) } }
                        }
                    }
                }
            }
            if !model.notice.isEmpty { Section { Text(model.notice).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle(model.showDeleted ? "账号回收站" : "号池管理")
        .searchable(text: $model.query, prompt: "搜索邮箱、备注或订阅")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button(model.showDeleted ? "返回号池" : "回收站") { model.showDeleted.toggle(); model.query = ""; model.filter = nil } }
            if !model.showDeleted {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("新增账号", systemImage: "plus") {
                        Button("注册新账号并入库") { model.beginConnection(.register) }
                        Button("接入已有账号") { model.beginConnection(.existing) }
                        Button("手动记录账号", action: model.create)
                    }.disabled(model.store.loadError != nil)
                }
            }
        }
        .sheet(isPresented: $model.showEditor) { MobileAccountEditor(model: model) }
    }
    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value).font(.footnote) }
    }
}

private struct MobileAccountEditor: View {
    @ObservedObject var model: AccountPoolModel
    @State private var confirmDiscard = false
    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    TextField("账号邮箱", text: $model.draft.email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("备注名（选填）", text: $model.draft.label)
                    Picker("状态", selection: $model.draft.status) { ForEach(AccountPoolStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                }
                Section("订阅") {
                    TextField("订阅类型，例如 Pro、Max", text: $model.draft.subscription)
                    Toggle("记录到期日", isOn: Binding(get: { model.draft.expiresAt != nil }, set: { model.draft.expiresAt = $0 ? Date() : nil }))
                    if model.draft.expiresAt != nil { DatePicker("到期日", selection: Binding(get: { model.draft.expiresAt ?? Date() }, set: { model.draft.expiresAt = $0 }), displayedComponents: .date) }
                }
                Section("记录信息") {
                    DatePicker("创建时间", selection: $model.draft.createdAt)
                    TextField("备注（选填）", text: $model.draft.notes, axis: .vertical).lineLimit(3...6)
                }
                if !model.editorError.isEmpty { Section { Text(model.editorError).foregroundStyle(.orange) } }
                Section { Text("本地记账，不执行账号登录或认证。").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(model.editorTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { if model.hasUnsavedChanges { confirmDiscard = true } else { model.cancel() } } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: model.save) }
            }
            .confirmationDialog("放弃尚未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) { Button("放弃修改", role: .destructive, action: model.cancel) }
            .interactiveDismissDisabled(model.hasUnsavedChanges)
        }.tint(MobileStyle.accent)
    }
}
