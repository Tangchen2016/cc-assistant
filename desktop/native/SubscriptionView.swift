import SwiftUI

struct SubscriptionView: View {
    @ObservedObject var model: SubscriptionModel
    @ObservedObject var server: SubscriptionServer
    private var routeAccent: Color { Theme.accent }
    private var selected: SubscriptionGroup? { model.profile.groups.indices.contains(model.selectedGroup) ? model.profile.groups[model.selectedGroup] : nil }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(title: "线路", subtitle: headerSubtitle) { EmptyView() }
                    HStack(spacing: 12) {
                        Picker("线路类型", selection: Binding(get: { model.client == "clash" ? "clash" : "static" }, set: model.selectClient)) {
                            Text("静态 IP 节点").tag("static")
                            Text("固定机场节点").tag("clash")
                        }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(model.busy)
                        Spacer()
                        if model.client == "static" {
                            Button("新增节点") { model.editStaticNode() }.buttonStyle(AddButtonStyle()).disabled(model.busy)
                        } else if model.stage == "list" {
                            Button("新增线路", action: model.create).buttonStyle(AddButtonStyle()).disabled(model.busy)
                        }
                    }
                    if model.client == "clash" && model.addressMode == .local && !server.ready { HStack { Text(server.status).font(.system(size: 12)); Spacer(); Button("重试本机服务") { server.start() } }.padding(14).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)) }
                    if !model.error.isEmpty { Text(model.error).foregroundStyle(.orange).font(.system(size: 12)).textSelection(.enabled) }
                    if !model.message.isEmpty { Text(model.message).foregroundStyle(.secondary).font(.system(size: 12)) }
                    if model.client == "static" { StaticProxyNodesView(model: model) }
                    else if model.stage == "list" { library }
                    else {
                        HStack(alignment: .top, spacing: 18) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(model.currentId == nil ? "新增\(model.profile.isShadowrocket ? "手机线路" : "增强订阅")" : "编辑\(model.profile.isShadowrocket ? "手机线路" : "增强订阅")").font(.system(size: 17, weight: .semibold))
                                Text(model.profile.isShadowrocket ? "仅配置静态出口；手机继续使用原订阅，Claude 由专用规则转发。" : "为 Claude 指定独立线路；按需启用前置代理，固定最终出口 IP。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(action: model.list) { Label("配置列表", systemImage: "arrow.left") }.buttonStyle(.borderless).font(.system(size: 12))
                        }
                        if model.stage != "done" && !model.profile.isShadowrocket { steps }
                        if model.stage == "source" { sourceForm }
                        if model.stage == "configure" { if model.profile.isShadowrocket { ShadowrocketRouteForm(model: model) } else { configuration } }
                        if model.stage == "review" { review }
                        if model.stage == "done", let record = model.current { if record.profile.isShadowrocket { ShadowrocketRouteOutput(model: model, record: record) } else { output(record) } }
                    }
                }.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 32).frame(maxWidth: model.stage == "configure" ? 1180 : Theme.contentWidth, alignment: .leading)
            }.frame(maxWidth: .infinity).disabled(model.busy)
            if model.stage == "configure" && !model.profile.isShadowrocket { configurationActions }
            if model.busy { HStack { ProgressView().controlSize(.small); Text("正在处理…").font(.system(size: 11)); Spacer() }.padding(12) }
        }.background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: model.profile) { _, _ in model.draft() }
            .onChange(of: model.selectedGroup) { _, _ in model.showFixed = false }
            .sheet(item: $model.qrRecord) { record in SubscriptionQRCode(record: record, mode: $model.qrMode, close: { model.qrRecord = nil }) }
            .sheet(isPresented: $model.showStaticNodeEditor) { StaticProxyNodeEditor(model: model) }
            .sheet(isPresented: Binding(get: { model.clashOverrideLink != nil }, set: { if !$0 { model.clashOverrideLink = nil } })) { if let link = model.clashOverrideLink { ClashOverrideSheet(model: model, link: link) } }
            .sheet(isPresented: $model.showGuide) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("静态代理部署说明").font(.title2); Spacer(); Button("关闭") { model.showGuide = false } }
                    ScrollView { Text(model.guide).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Text("缺少 SSH 信息先询问，最终交付可直接粘贴的完整 URL。").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button("复制完整说明") { model.copy(model.guide) } }
                }.padding(24).frame(width: 760, height: 560)
            }
    }
    private var headerSubtitle: String {
        switch model.client {
        case "static": return "固定出口 IP。Claude 经机场节点链式连接到静态出口，直接导入 Clash 覆写或 Shadowrocket，无需增强订阅。"
        case "shadowrocket": return "静态 IP 节点的手机线路：小火箭直连静态出口，可在手机上另选前置。"
        default: return "没有静态 IP 时使用：从机场订阅中为 Claude 指定节点，生成增强订阅地址。"
        }
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let draft = model.storage.state.draft, draft.isShadowrocket == (model.client == "shadowrocket"), (!draft.sourceUrl.isEmpty || !(draft.groups.first?.fixedExit ?? "").isEmpty), model.hasUnfinishedDraft {
                HStack(spacing: 12) {
                    Image(systemName: "pencil.line").foregroundStyle(.secondary)
                    Text("有一份未完成的配置").font(.system(size: 12))
                    Spacer()
                    Button("继续配置", action: model.resume).buttonStyle(.borderless)
                }.card(padding: 14)
            }
            if model.visibleRecords.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("添加你的第一条线路").font(.headline)
                    Text(model.client == "shadowrocket" ? "选择一个静态IP节点，不需要提供日常订阅地址。" : "导入机场订阅，为 Claude 选择节点，再生成增强地址。有静态 IP 时请直接用「静态 IP 节点」。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Button("新增线路", action: model.create).buttonStyle(.bordered).controlSize(.large)
                }.frame(maxWidth: .infinity, minHeight: 260).card()
            } else {
                HStack {
                    Text("已保存线路").font(.system(size: 12, weight: .medium))
                    Text("\(model.visibleRecords.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                }.foregroundStyle(.secondary)
                VStack(spacing: 12) {
                    ForEach(model.visibleRecords) { record in routeCard(record) }
                }
            }
        }.padding(.top, 2)
    }
    private func routeCard(_ record: SubscriptionRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 7) {
                    Text(record.profile.name).font(.system(size: 15, weight: .semibold))
                    Text(record.profile.isShadowrocket ? "独立静态出口 · 前置在小火箭中选择" : URL(string: record.profile.sourceUrl)?.host ?? "源订阅")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                Label(record.remote == nil ? (record.preferredAddressMode == .remote ? "远程待发布" : "本机订阅") : record.remote?.lastError == nil ? "远程已发布" : "远程同步异常", systemImage: record.preferredAddressMode == .remote ? "cloud" : "desktopcomputer")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04), in: Capsule())
            }.padding(20)
            HStack(spacing: 18) {
                Label(record.profile.isShadowrocket ? "固定出口" : record.profile.groups.contains(where: { $0.chain != nil }) ? "链式代理" : "指定节点", systemImage: "point.3.connected.trianglepath.dotted")
                Text(record.profile.isShadowrocket ? "无需源订阅" : "\(record.profile.groups.count) 个代理组")
                Text("\(record.profile.rules.count) 条域名规则")
                Spacer()
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 18)
            Divider().opacity(0.6)
            HStack(spacing: 10) {
                Button { model.qrRecord = record } label: { Label("手机扫码", systemImage: "qrcode") }
                Button { if let address = record.preferredURL { model.copy(address) } } label: { Label("复制地址", systemImage: "doc.on.doc") }
                    .disabled(record.preferredURL == nil)
                Spacer()
                Button("查看地址") { model.showAddresses(record) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                Button { model.open(record) } label: { Label("编辑", systemImage: "slider.horizontal.3") }
                Menu {
                    Button("删除线路", role: .destructive) { model.deleteId = record.id }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("更多线路操作").help("更多操作")
            }.controlSize(.regular).padding(.horizontal, 20).padding(.vertical, 14)
            if model.deleteId == record.id {
                Divider()
                HStack {
                    Text(record.remote == nil ? "删除后本机链接失效。" : "请先在地址页停用远程订阅。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { model.deleteId = nil }
                    Button("确认删除", role: .destructive) { model.remove(record.id) }.disabled(record.remote != nil)
                }.padding(16)
            }
        }
        .card(padding: 0)
    }
    private var steps: some View {
        let active = model.stage == "source" ? 1 : model.stage == "configure" ? 2 : 3
        return HStack(spacing: 8) {
            stepButton(1, title: "输入订阅", active: active, disabled: false) { model.stage = "source" }
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            stepButton(2, title: "详细配置", active: active, disabled: model.source == nil && model.currentId == nil) { model.stage = "configure" }
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            stepButton(3, title: "确认并生成", active: active, disabled: model.source == nil, action: model.review)
        }.card(padding: 6)
    }
    private func stepButton(_ number: Int, title: String, active: Int, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(active == number ? routeAccent : Color.primary.opacity(0.06))
                    if number < active { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                    else { Text("\(number)").font(.system(size: 11, weight: .semibold)) }
                }.frame(width: 24, height: 24).foregroundStyle(active == number ? Color.white : Color.secondary)
                Text(title).font(.system(size: 12, weight: active == number ? .semibold : .medium))
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(active == number ? routeAccent : Color.primary)
                .background(active == number ? routeAccent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(disabled)
    }
    private var sourceForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("源订阅地址").font(.headline)
            HStack { Group { if model.showSource { TextField("https://…", text: Binding(get: { model.profile.sourceUrl }, set: model.sourceChanged)) } else { SecureField("https://…", text: Binding(get: { model.profile.sourceUrl }, set: model.sourceChanged)) } }.textFieldStyle(.roundedBorder)
                Button { model.showSource.toggle() } label: { Image(systemName: model.showSource ? "eye.slash" : "eye") }.help("显示或隐藏源订阅") }
            Text("支持包含内嵌节点的 Clash / Mihomo YAML。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("确定并继续", action: model.inspect).buttonStyle(.borderedProminent).tint(Theme.accent).disabled(model.profile.sourceUrl.isEmpty) }
        }.card(padding: 22)
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Label("\(model.source?.nodes.count ?? 0) 个节点", systemImage: "server.rack")
                Text("· \(model.source?.groups.count ?? 0) 个原有代理组")
                Spacer()
                Button(action: model.inspect) { Label("刷新节点", systemImage: "arrow.clockwise") }.buttonStyle(.borderless)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 2)
            HStack(alignment: .top, spacing: 20) {
                groupEditor.frame(minWidth: 340, maxWidth: .infinity, alignment: .topLeading)
                ruleEditor.frame(minWidth: 340, maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
    private var configurationActions: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 14) {
                Button { model.stage = "source" } label: { Label("更换源订阅", systemImage: "arrow.left") }.buttonStyle(.bordered)
                Text("确认前置节点、固定出口与域名规则后继续。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: model.review) { Label("下一步：确认配置", systemImage: "arrow.right") }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }.controlSize(.large).padding(.horizontal, 28).padding(.vertical, 15)
        }.background(Color(nsColor: .windowBackgroundColor)).disabled(model.busy)
    }
    private func editorCard<Content: View>(_ title: String, subtitle: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(routeAccent)
                    .frame(width: 32, height: 32).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Divider().opacity(0.5)
            content()
        }.card()
    }
    private var groupEditor: some View {
        editorCard("独立代理组", subtitle: "订阅节点使用普通规则组，静态IP出口可按需经前置连接。", symbol: "arrow.triangle.branch") {
            HStack(spacing: 10) {
                if selected != nil {
                    TextField("代理组名称", text: Binding(get: { selected?.name ?? "" }, set: model.renameGroup))
                        .textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel("代理组名称")
                } else {
                    Text("尚未添加代理组").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                Menu {
                    if model.profile.groups.count > 1 {
                        Picker("切换代理组", selection: $model.selectedGroup) {
                            ForEach(model.profile.groups.indices, id: \.self) { index in Text(model.profile.groups[index].name).tag(index) }
                        }
                        Divider()
                    }
                    Button(action: model.addGroup) { Label("新增代理组", systemImage: "plus") }.disabled(model.profile.groups.count >= 10)
                    Button(role: .destructive, action: model.removeGroup) { Label("删除当前组", systemImage: "trash") }.disabled(selected == nil)
                } label: { Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24, height: 30)
                    .foregroundStyle(.secondary).accessibilityLabel("管理代理组").help("切换、新增或删除代理组")
            }
            if let group = selected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最终出口").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("最终出口", selection: Binding(get: { selected?.fixedExit != nil }, set: model.setExitSource)) { Text("订阅节点").tag(false); Text("静态IP节点").tag(true) }
                        .pickerStyle(.segmented).labelsHidden()
                    Text(group.fixedExit != nil ? "最终出口固定在所选静态IP节点；需要中转时，再启用下方的链式代理。" : "普通规则组：本机 → 订阅节点 → Claude。出口 IP 可能随服务商调整或节点切换而变化。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if group.fixedExit != nil {
                    StaticNodeAssociation(model: model, group: model.selectedGroup)
                    staticChainControls(group)
                    HStack {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("需要新的固定出口？").foregroundStyle(.secondary)
                        Button("用 AI 部署") { model.showGuide = true }.buttonStyle(.borderless)
                    }.font(.system(size: 11))
                    Text("固定出口规则会拒绝 UDP；浏览器通常回退到 TCP。节点凭据请私密保存。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    if group.chain != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("这份旧配置包含订阅节点链式连接。请改为普通规则组，或切换到静态IP出口后再保存。")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                            Button("改为普通规则组") { model.setChainEnabled(false) }.buttonStyle(.borderless)
                        }.padding(12).background(Color.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                    nodeList
                }
            } else { Text("请先添加代理组").font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
    private func staticChainControls(_ group: SubscriptionGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("通过前置连接静态IP（链式代理）", isOn: Binding(get: { selected?.chain != nil }, set: model.setChainEnabled))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12, weight: .medium))
            if group.chain != nil {
                VStack(alignment: .leading, spacing: 7) {
                    Text("前置代理组（来自源订阅）").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("前置代理组", selection: Binding(get: { selected?.chain?.entry ?? "" }, set: { model.profile.groups[model.selectedGroup].chain?.entry = $0; model.draft() })) {
                        Text("自动 · 源订阅全部节点测速（推荐）").tag(SubscriptionCore.autoChainEntry)
                        Text("请选择前置代理组").tag("")
                        ForEach(model.source?.groupNames ?? [], id: \.self) { Text($0).tag($0) }
                        if group.chain?.entry == "DIRECT" { Text("DIRECT").tag("DIRECT") }
                    }.labelsHidden().pickerStyle(.menu).controlSize(.large).tint(.primary).frame(maxWidth: .infinity, alignment: .leading)
                }
                Label(group.chain?.entry == SubscriptionCore.autoChainEntry ? "本机 → 延迟最低的机场节点 → 静态IP出口 → Claude（与手动选的节点无关）" : "本机 → 机场前置 → 静态IP出口 → Claude", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("本机直接连接静态IP出口。启用前置后，最终出口 IP 保持不变。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(14).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }
    private var filteredNodes: [String] {
        (model.source?.nodes.compactMap { $0["name"] as? String } ?? []).filter { (model.search.isEmpty || $0.localizedCaseInsensitiveContains(model.search)) && (!model.onlyUS || SubscriptionModel.isUS($0)) }.sorted { a, b in let aa = SubscriptionModel.isUS(a), bb = SubscriptionModel.isUS(b); return aa == bb ? a < b : aa }
    }
    private var nodeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已选：" + (selected?.nodes.joined(separator: "、") ?? "")).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("搜索节点", text: $model.search)
            HStack { Toggle("仅看美国", isOn: $model.onlyUS); Spacer(); Button(model.measuring ? "检测中…" : "检测列表") { model.measure(filteredNodes) }.disabled(model.measuring) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(filteredNodes, id: \.self) { name in
                    HStack { Toggle(name, isOn: Binding(get: { selected?.nodes.contains(name) ?? false }, set: { enabled in if enabled { model.profile.groups[model.selectedGroup].nodes.append(name) } else { model.profile.groups[model.selectedGroup].nodes.removeAll { $0 == name } }; model.draft() })); Spacer(); Text(model.delays[name] ?? "—").font(.system(size: 10)).foregroundStyle(.secondary); Button { model.measure([name]) } label: { Image(systemName: "gauge") }.help("检测此节点延迟").disabled(model.measuring) }
                }
            }.padding(8) }.frame(height: 250)
            Text("美国节点按名称识别；延迟经所选节点实际请求 HTTPS 测试网站。").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var ruleEditor: some View {
        editorCard("域名转发规则", subtitle: "匹配这些域名的请求优先使用指定代理组。", symbol: "list.bullet.rectangle") {
            HStack {
                Text("\(model.profile.rules.count) 条规则").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("优先匹配").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Color.primary.opacity(0.04), in: Capsule())
            }
            ForEach(model.profile.rules.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", i + 1)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                        Picker("匹配方式 \(i + 1)", selection: Binding(get: { model.profile.rules.indices.contains(i) ? model.profile.rules[i].type : "DOMAIN-SUFFIX" }, set: { guard model.profile.rules.indices.contains(i) else { return }; model.profile.rules[i].type = $0; model.draft() })) { Text("域名后缀").tag("DOMAIN-SUFFIX"); Text("完整域名").tag("DOMAIN"); Text("关键词").tag("DOMAIN-KEYWORD") }
                            .labelsHidden().pickerStyle(.menu).controlSize(.small).tint(.primary)
                        Spacer()
                        Button { model.profile.rules.remove(at: i); model.draft() } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("删除此规则").accessibilityLabel("删除规则 \(i + 1)")
                    }
                    TextField("example.com", text: Binding(get: { model.profile.rules.indices.contains(i) ? model.profile.rules[i].value : "" }, set: { guard model.profile.rules.indices.contains(i) else { return }; model.profile.rules[i].value = $0; model.draft() }))
                        .textFieldStyle(.roundedBorder).controlSize(.large).font(.system(size: 12, design: .monospaced))
                        .accessibilityLabel("匹配域名 \(i + 1)")
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("转发到").font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker("目标代理组 \(i + 1)", selection: Binding(get: { model.profile.rules.indices.contains(i) ? model.profile.rules[i].group : "" }, set: { guard model.profile.rules.indices.contains(i) else { return }; model.profile.rules[i].group = $0; model.draft() })) { ForEach(model.profile.groups.map(\.name), id: \.self) { Text($0).tag($0) } }
                            .labelsHidden().pickerStyle(.menu).controlSize(.small).tint(.primary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(14).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.04), lineWidth: 1))
            }
            HStack {
                Button { model.profile.rules.append(.init(type: "DOMAIN-SUFFIX", value: "", group: selected?.name ?? "")); model.draft() } label: { Label("添加域名规则", systemImage: "plus") }
                    .disabled(model.profile.rules.count >= 100)
                Button { model.addRecommendedRules() } label: { Label("补全推荐规则", systemImage: "wand.and.stars") }
                    .disabled(model.missingRecommendedRules == 0)
                    .help("补充 Claude 及其页面加载的认证、遥测、客服、反欺诈等域名（缺 \(model.missingRecommendedRules) 条），转发到 Claude 所在代理组")
            }.buttonStyle(.bordered).controlSize(.large)
        }
    }
    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认增强订阅").font(.headline)
            TextField("订阅名称", text: $model.profile.name).textFieldStyle(.roundedBorder)
            ForEach(model.profile.groups.indices, id: \.self) { i in let g = model.profile.groups[i]; Text(g.name + "：" + (g.chain.map { ($0.entry == SubscriptionCore.autoChainEntry ? "自动测速前置" : $0.entry) + " → " } ?? "") + (g.fixedExit != nil ? "自建固定出口" : g.nodes.joined(separator: "、"))) }
            ForEach(model.profile.rules.indices, id: \.self) { i in Text(model.profile.rules[i].value + " → " + model.profile.rules[i].group).font(.system(size: 12)) }
            Divider()
            addressPicker
            HStack { Button("返回修改") { model.stage = "configure" }; Spacer(); Button(model.addressMode == .remote ? "保存并生成远程地址" : "保存并生成本地地址", action: model.save).buttonStyle(.borderedProminent).tint(Theme.accent) }
        }.card(padding: 22)
    }
    private var addressPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("地址类型").font(.system(size: 12, weight: .medium))
            Picker("地址类型", selection: Binding(get: { model.addressMode }, set: model.selectAddressMode)) {
                Text("远程 · 推荐").tag(SubscriptionAddressMode.remote)
                Text("本地").tag(SubscriptionAddressMode.local)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 260)
            Text(model.addressMode == .remote ? "直接发布远程订阅，无需先生成本机地址。发布后可独立下载，Mac 无需保持在线。" : "用于这台 Mac，需要 cc助手保持运行。切换地址类型不会停用已发布的远程订阅。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private func output(_ record: SubscriptionRecord) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(record.profile.name).font(.title2)
            addressPicker
            Divider()
            if model.addressMode == .remote {
                Text("远程订阅地址").font(.headline)
                if let remote = record.remote {
                    Text(remote.subscriptionUrl).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    if let error = remote.lastError { Text(error).foregroundStyle(.orange) }
                    HStack { Button("复制远程地址") { model.copy(remote.subscriptionUrl) }; Button("导入 Clash Party") { model.importClash(record, remote: true) }; Button(remote.lastError == nil ? "同步更新" : "重试发布", action: model.syncRemote); Button("停用远程订阅", action: model.stopRemote) }
                } else {
                    Text("远程地址尚未生成，可直接重试，无需重新配置。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("重试发布", action: model.syncRemote).buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            } else {
                Text("本机订阅地址").font(.headline)
                Text(record.localURL).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                HStack { Button("复制本机地址") { model.copy(record.localURL) }; Button("导入 Clash Party") { model.importClash(record) }.disabled(!server.ready) }
            }
            Divider()
            HStack { Button("编辑") { model.open(record) }; Spacer(); Button("完成，返回列表", action: model.list) }
        }.card(padding: 22)
    }
}

/// Accent-tinted pill with a filled plus badge; quieter than a prominent button, clearer than a bare icon.
struct AddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { AddButtonBody(configuration: configuration) }
}
private struct AddButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Theme.accent, in: Circle())
            configuration.label.font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accent)
        }
        .padding(.leading, 6).padding(.trailing, 13).padding(.vertical, 5)
        .background(Theme.accent.opacity(configuration.isPressed ? 0.2 : hovering ? 0.14 : 0.09), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(hovering ? 0.35 : 0.2), lineWidth: 0.5))
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
