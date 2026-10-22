import Foundation

enum StaticProxyLibrary {
    static func identity(_ url: String) throws -> Data { try JSONSerialization.data(withJSONObject: SubscriptionCore.fixedExit(url), options: .sortedKeys) }
    /// Mihomo JS override (Clash Party / Clash Verge Rev): Claude domains → any airport node (url-test) → this static exit.
    /// Works on every subscription because the front group collects nodes itself instead of naming airport groups.
    static func clashOverride(_ node: StaticProxyNode) throws -> String {
        let exit = "Claude 固定线路", hop = "Claude 固定线路 · 前置"
        var proxy = try SubscriptionCore.fixedExit(node.url); proxy["name"] = exit; proxy["dialer-proxy"] = hop
        // include-all also covers proxy-providers; exclude-filter keeps the exit out of its own front, plus airport info nodes.
        let group: [String: Any] = ["name": hop, "type": "url-test", "include-all": true, "exclude-filter": "(?i)Claude 固定线路|剩余|到期|过期|官网|流量|套餐|重置|expire|traffic|remaining", "url": "https://www.gstatic.com/generate_204", "interval": 300, "tolerance": 50]
        let rules = ClaudeRules.recommended.flatMap { ["AND,((\($0.type),\($0.value)),(NETWORK,UDP)),REJECT", "\($0.type),\($0.value),\(exit)"] }
        func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
        return """
        // Claude 固定线路 · \(node.name)：Claude 相关域名 → 机场延迟最低节点 → 静态出口。与机场订阅和所选节点无关。
        // 含节点凭据，请勿公开。
        function main(config) {
          const names = new Set([...(config.proxies || []), ...(config["proxy-groups"] || [])].map(item => item.name));
          if (names.has("\(exit)") || names.has("\(hop)")) return config;
          config.proxies = [...(config.proxies || []), \(try json(proxy))];
          config["proxy-groups"] = [...(config["proxy-groups"] || []), \(try json(group))];
          config.rules = [...\(try json(rules)), ...(config.rules || [])];
          return config;
        }

        """
    }
    static func validate(_ nodes: [StaticProxyNode]) throws {
        guard nodes.count <= 100, Set(nodes.map(\.id)).count == nodes.count else { throw SubscriptionFailure("静态IP节点数量超限或标识重复") }
        for node in nodes {
            guard SubscriptionStorage.valid(node.id, length: 32), !node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, node.name.count <= 100, !node.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw SubscriptionFailure("静态IP节点名称或标识无效") }
            _ = try identity(node.url)
        }
    }
    static func resolved(_ input: SubscriptionProfile, nodes: [StaticProxyNode]) throws -> SubscriptionProfile {
        var profile = input
        for i in profile.groups.indices {
            if let id = profile.groups[i].staticNodeId {
                guard let node = nodes.first(where: { $0.id == id }) else { throw SubscriptionFailure("关联的静态IP节点不存在，请重新选择") }
                profile.groups[i].fixedExit = node.url
            }
        }
        return profile
    }
    @discardableResult static func link(_ profile: inout SubscriptionProfile, state: inout SubscriptionState) throws -> Bool {
        let before = profile
        var nodes = state.staticNodes ?? []
        for i in profile.groups.indices {
            if profile.groups[i].staticNodeId != nil { continue }
            guard let raw = profile.groups[i].fixedExit, !raw.isEmpty, let key = try? identity(raw) else { continue }
            let node: StaticProxyNode
            if let existing = nodes.first(where: { (try? identity($0.url)) == key }) { node = existing }
            else {
                guard nodes.count < 100 else { throw SubscriptionFailure("最多保存 100 个静态IP节点") }
                let base = String(("静态出口 · " + (URLComponents(string: raw)?.host ?? "节点")).prefix(90))
                var name = base; var index = 2
                while nodes.contains(where: { $0.name == name }) { name = "\(base) \(index)"; index += 1 }
                node = .init(id: try SubscriptionCore.token(16), name: name, url: raw); nodes.append(node)
            }
            profile.groups[i].staticNodeId = node.id
        }
        profile = try resolved(profile, nodes: nodes)
        state.staticNodes = nodes
        return profile != before
    }
    static func migrate(_ state: inout SubscriptionState) throws -> Bool {
        try validate(state.staticNodes ?? [])
        var changed = state.staticNodes == nil
        state.staticNodes = state.staticNodes ?? []
        for i in state.records.indices {
            var profile = state.records[i].profile
            if try link(&profile, state: &state) { changed = true }
            state.records[i].profile = profile
        }
        if var draft = state.draft { if try link(&draft, state: &state) { changed = true }; state.draft = draft }
        return changed
    }
}

extension SubscriptionStorage {
    var staticNodes: [StaticProxyNode] { state.staticNodes ?? [] }
    func resolved(_ profile: SubscriptionProfile) throws -> SubscriptionProfile { try StaticProxyLibrary.resolved(profile, nodes: staticNodes) }
    func staticNodeUsages(_ id: String) -> [String] {
        var uses = state.records.filter { $0.profile.groups.contains { $0.staticNodeId == id } }.map { $0.profile.name }
        if let draft = state.draft, draft.groups.contains(where: { $0.staticNodeId == id }), draft != state.records.first(where: { $0.id == state.currentId })?.profile { uses.append("未完成配置") }
        return uses
    }
    @discardableResult func saveStaticNode(id: String?, name: String, url: String) throws -> StaticProxyNode {
        var next = state
        var node = StaticProxyNode(id: try id ?? SubscriptionCore.token(16), name: name.trimmingCharacters(in: .whitespacesAndNewlines), url: url.trimmingCharacters(in: .whitespacesAndNewlines))
        node.overrideKey = staticNodes.first(where: { $0.id == node.id })?.overrideKey
        var nodes = staticNodes
        if let id { guard nodes.contains(where: { $0.id == id }) else { throw SubscriptionFailure("静态IP节点已删除") } }
        let key = try StaticProxyLibrary.identity(node.url)
        guard !nodes.contains(where: { $0.id != node.id && ($0.name.caseInsensitiveCompare(node.name) == .orderedSame || (try? StaticProxyLibrary.identity($0.url)) == key) }) else { throw SubscriptionFailure("节点名称或出口已存在，请直接关联已有节点") }
        nodes.removeAll { $0.id == node.id }; nodes.append(node)
        try StaticProxyLibrary.validate(nodes); next.staticNodes = nodes
        for i in next.records.indices {
            let updated = try StaticProxyLibrary.resolved(next.records[i].profile, nodes: nodes)
            if updated != next.records[i].profile {
                next.records[i].profile = updated; next.records[i].updatedAt = Date().timeIntervalSince1970 * 1000
                if next.records[i].remote != nil { next.records[i].remote?.lastError = "静态IP节点已更新，等待同步" }
            }
        }
        if let draft = next.draft { next.draft = try StaticProxyLibrary.resolved(draft, nodes: nodes) }
        try commit(next); return node
    }
    /// Stable secret for the node's override URL; created on first use and kept across node edits.
    func overrideKey(_ id: String) throws -> String {
        guard let index = staticNodes.firstIndex(where: { $0.id == id }) else { throw SubscriptionFailure("静态IP节点已删除") }
        if let key = staticNodes[index].overrideKey { return key }
        var next = state; let key = try SubscriptionCore.token(32); next.staticNodes![index].overrideKey = key; try commit(next); return key
    }
    func removeStaticNode(_ id: String) throws {
        guard staticNodeUsages(id).isEmpty else { throw SubscriptionFailure("节点正在被线路或草稿使用，请先解除关联") }
        var next = state; next.staticNodes = staticNodes.filter { $0.id != id }; try commit(next)
    }
}
