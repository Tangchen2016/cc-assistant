import SwiftUI

struct StaticNodeAssociation: View {
    @ObservedObject var model: SubscriptionModel
    let group: Int
    private var selectedId: String { model.profile.groups.indices.contains(group) ? model.profile.groups[group].staticNodeId ?? "" : "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关联静态IP节点").font(.system(size: 12, weight: .medium))
            Picker("静态IP节点", selection: Binding(get: { selectedId }, set: { model.associateStaticNode($0, group: group) })) {
                Text("请选择已保存的节点").tag("")
                ForEach(model.staticNodes) { node in Text(node.name).tag(node.id) }
            }.labelsHidden().pickerStyle(.menu).controlSize(.large).tint(.primary).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button("新增静态IP节点") { model.editStaticNode(linkGroup: group) }
                if let node = model.staticNodes.first(where: { $0.id == selectedId }) {
                    Button("编辑共享节点") { model.editStaticNode(node, linkGroup: group) }
                }
            }.buttonStyle(.borderless).font(.system(size: 11))
            Text("同一节点可供 Clash 和小火箭复用，修改一次即可更新关联线路。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct StaticProxyNodesView: View {
    @ObservedObject var model: SubscriptionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.staticNodes.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "server.rack").font(.system(size: 30)).foregroundStyle(Theme.accent)
                        .frame(width: 64, height: 64).background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("添加一个静态 IP 出口").font(.headline)
                    Text("粘贴 VLESS 分享链接，之后一键导入 Clash 或 Shadowrocket。").font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button { model.editStaticNode() } label: { Label("新增节点", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(Theme.accent)
                        Button("用 AI 部署静态代理") { model.showGuide = true }
                    }.controlSize(.large)
                }.frame(maxWidth: .infinity, minHeight: 280).card()
            } else {
                ForEach(model.staticNodes) { node in card(node) }
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                    Text("还没有静态出口服务器？").foregroundStyle(.secondary)
                    Button("用 AI 部署静态代理") { model.showGuide = true }.buttonStyle(.link)
                }.font(.system(size: 12)).padding(.top, 4)
            }
        }
    }
    private func card(_ node: StaticProxyNode) -> some View {
        let uses = model.storage.staticNodeUsages(node.id)
        let published = model.records.contains { $0.remote != nil && $0.profile.groups.contains { $0.staticNodeId == node.id } }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "server.rack").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: 42, height: 42).background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(node.name).font(.system(size: 15, weight: .semibold))
                    Text("VLESS · WebSocket + TLS · " + (URLComponents(string: node.url)?.host ?? "固定出口")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                Menu {
                    Button("编辑节点") { model.editStaticNode(node) }
                    Button("复制分享 URL") { model.copy(node.url) }
                    if published { Button("同步已发布线路") { model.syncStaticNode(node.id) } }
                    Divider()
                    Button("删除节点", role: .destructive) { model.deletingStaticNodeId = node.id }.disabled(!uses.isEmpty)
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(uses.isEmpty ? "更多操作" : "更多操作（删除前需先解除关联）")
            }.padding(20)
            HStack(spacing: 12) {
                importButton("Clash", detail: "导入覆写 · 任意订阅通用", symbol: "link") { model.showClashOverride(node) }
                importButton("Shadowrocket", detail: model.shadowrocketRecord(for: node) == nil ? "生成手机线路 · 扫码导入" : "手机线路已生成 · 查看与扫码", symbol: "qrcode") { model.oneClickShadowrocket(node) }
            }.padding(.horizontal, 20).padding(.bottom, 20)
            if model.deletingStaticNodeId == node.id {
                Divider()
                HStack {
                    Text("删除后无法继续选择此节点。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { model.deletingStaticNodeId = nil }
                    Button("确认删除", role: .destructive) { model.removeStaticNode(node.id) }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
        }.card(padding: 0)
    }
    private func importButton(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }.buttonStyle(.plain)
    }
}

struct StaticProxyNodeEditor: View {
    @ObservedObject var model: SubscriptionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("静态IP节点配置").font(.title2)
            Text("保存一次，在 Clash 和小火箭中选择同一个节点即可。").font(.system(size: 13)).foregroundStyle(.secondary)
            TextField("节点名称，例如：美国固定出口", text: $model.staticNodeName).textFieldStyle(.roundedBorder)
            Text("静态代理分享 URL").font(.system(size: 12, weight: .medium))
            HStack {
                Group {
                    if model.revealStaticNodeURL { TextField("vless://…", text: $model.staticNodeURL) }
                    else { SecureField("vless://…", text: $model.staticNodeURL) }
                }.textFieldStyle(.roundedBorder)
                Button { model.revealStaticNodeURL.toggle() } label: { Image(systemName: model.revealStaticNodeURL ? "eye.slash" : "eye") }.help("显示或隐藏分享链接")
                Button { model.copy(model.staticNodeURL) } label: { Image(systemName: "doc.on.doc") }.help("复制分享链接")
            }
            Text("支持 VLESS + WebSocket + TLS。节点的 IP 或域名、端口和凭据均从 URL 中读取。").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("修改出口后会更新所有关联配置，并尝试同步已发布的线路；客户端刷新订阅后生效。小火箭刷新后请核对“代理通过”。").font(.system(size: 12)).foregroundStyle(.secondary)
            if !model.error.isEmpty { Text(model.error).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Button("取消") { model.showStaticNodeEditor = false }
                Spacer()
                Button("保存节点", action: model.saveStaticNode).buttonStyle(.borderedProminent).tint(Theme.accent).disabled(model.staticNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.staticNodeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 620).disabled(model.busy)
    }
}

struct ClashOverrideSheet: View {
    @ObservedObject var model: SubscriptionModel
    let link: String
    private let steps = [
        "点击「复制链接」，再点击「打开 Clash Party」。",
        "在 Clash Party 左侧进入「覆写」，把链接粘贴到顶部输入框，点击「导入」。",
        "在新出现的「Claude 固定线路」上打开「全局启用」开关（导入后默认关闭，只需开一次）。",
        "访问 claude.ai 验证：Clash Party「连接」中应显示 机场节点 → Claude 固定线路。",
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导入 Clash 覆写").font(.title2)
            Text("Claude 相关域名会经机场中延迟最低的节点，从此静态IP出口访问；与所用订阅和所选节点无关。").font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(link).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                Button("复制链接") { model.copy(link) }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18).background(Theme.accent.opacity(0.15), in: Circle())
                        Text(steps[i]).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("修改节点后，在 Clash Party 覆写页刷新这一项即可，无需重新导入；刷新时需 cc助手保持运行。链接含访问密钥，请勿分享。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("关闭") { model.clashOverrideLink = nil }
                Spacer()
                Button("打开 Clash Party") { model.openClashParty() }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }.padding(26).frame(width: 560)
    }
}
