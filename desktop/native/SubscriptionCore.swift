import Foundation
import Security
import CryptoKit
import Yams

struct SubscriptionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
struct SubscriptionChain: Codable, Equatable { var entry: String }
struct SubscriptionGroup: Codable, Equatable { var name: String; var nodes: [String]; var chain: SubscriptionChain?; var fixedExit: String?; var staticNodeId: String? = nil }
struct StaticProxyNode: Codable, Equatable, Identifiable { var id: String; var name: String; var url: String; var overrideKey: String? = nil }
struct SubscriptionRule: Codable, Equatable { var type: String; var value: String; var group: String }
struct SubscriptionProfile: Codable, Equatable {
    var name: String; var sourceUrl: String; var groups: [SubscriptionGroup]; var rules: [SubscriptionRule]
    var client: String? = nil
    var isShadowrocket: Bool { client == "shadowrocket" }
    static var empty: Self { Self(name: "Claude 专属订阅", sourceUrl: "", groups: [.init(name: "Claude 固定节点", nodes: [])], rules: ClaudeRules.rules(group: "Claude 固定节点")) }
    static var mobile: Self { var value = empty; value.client = "shadowrocket"; value.name = "Claude 手机线路"; value.groups[0].fixedExit = ""; value.rules = ClaudeRules.rules(group: value.groups[0].name, mobile: true); return value }
}
struct SubscriptionRemote: Codable, Equatable { var id: String; var manageKey: String; var downloadKey: String; var subscriptionUrl: String; var updatedAt: Double; var lastError: String? }
enum SubscriptionAddressMode: String, Codable { case remote, local }
struct SubscriptionRecord: Codable, Identifiable, Equatable {
    var id: String; var manageKey: String; var downloadKey: String; var profile: SubscriptionProfile; var updatedAt: Double; var remote: SubscriptionRemote?
    var addressMode: SubscriptionAddressMode? = nil
    var preferredAddressMode: SubscriptionAddressMode { profile.isShadowrocket ? .remote : addressMode ?? (remote == nil ? .local : .remote) }
    var preferredURL: String? { preferredAddressMode == .remote ? remote?.subscriptionUrl : localURL }
    var localURL: String { "http://127.0.0.1:19473/sub/\(id)/\(downloadKey)/\(SubscriptionCore.encoded(SubscriptionCore.filename(profile.name)))" }
}
struct SubscriptionState: Codable { var version = 1; var records: [SubscriptionRecord] = []; var currentId: String?; var draft: SubscriptionProfile?; var staticNodes: [StaticProxyNode]? = nil; var draftAddressMode: SubscriptionAddressMode? = nil }
struct SubscriptionSource: @unchecked Sendable {
    var config: [String: Any]; var fetchedAt: String; var sourceName: String?; var userInfo: String?
    var nodes: [[String: Any]] { config["proxies"] as? [[String: Any]] ?? [] }
    var groups: [[String: Any]] { config["proxy-groups"] as? [[String: Any]] ?? [] }
    var groupNames: [String] { groups.compactMap { $0["name"] as? String } }
}

enum SubscriptionCore {
    static let reserved: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "GLOBAL", "COMPATIBLE"]
    static func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? "" }
    static func filename(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/\\\u{2028}\u{2029}".unicodeScalars.contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "\\.ya?ml$", with: "", options: [.regularExpression, .caseInsensitive])
        return String((cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "增强-订阅" : cleaned).prefix(100)) + ".yaml"
    }
    static func token(_ bytes: Int) throws -> String {
        var data = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes, &data) == errSecSuccess else { throw SubscriptionFailure("无法生成安全链接密钥") }
        return data.map { String(format: "%02x", $0) }.joined()
    }
    static func publicURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 4096, let c = URLComponents(string: text), ["http", "https"].contains(c.scheme ?? ""), let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil, c.fragment == nil, c.port.map({ (1...65535).contains($0) }) ?? true, !host.contains(where: { $0.isWhitespace }), !["localhost", "localhost.localdomain"].contains(host), ![".local", ".internal", ".localhost"].contains(where: host.hasSuffix), let url = c.url else { throw SubscriptionFailure("请输入有效的公共 HTTP / HTTPS 地址，不含账号密码或片段") }
        let plain = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if EgressLocalDiagnostics.validIP(plain), !publicIP(plain) { throw SubscriptionFailure("不允许使用本机或内网地址") }
        return url
    }
    static func publicIP(_ raw: String) -> Bool {
        if raw.contains(":") { let s = raw.lowercased(); return s.hasPrefix("2") || s.hasPrefix("3") }
        let p = raw.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return !(p[0] == 0 || p[0] == 10 || p[0] == 127 || p[0] >= 224 || p[0] == 169 && p[1] == 254 || p[0] == 172 && (16...31).contains(p[1]) || p[0] == 192 && p[1] == 168 || p[0] == 100 && (64...127).contains(p[1]))
    }
    static func parse(_ text: String) throws -> [String: Any] {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw SubscriptionFailure("源订阅超过 2 MiB 限制") }
        // Bound YAML aliases before construction to avoid recursive / expanded alias graphs.
        guard !text.contains("!!"), text.components(separatedBy: "*").count < 101 else { throw SubscriptionFailure("YAML 标签或别名超出支持范围") }
        let loaded: Any?
        do {
            guard let root = try Yams.compose(yaml: text) else { throw SubscriptionFailure("配置为空") }
            var budget = 200000
            func verify(_ node: Node, depth: Int) throws {
                budget -= 1
                guard budget > 0, depth < 64 else { throw SubscriptionFailure("YAML 结构或别名展开过大") }
                switch node {
                case .scalar: break
                case .alias: throw SubscriptionFailure("不支持循环别名")
                case .sequence(let sequence): for child in sequence { try verify(child, depth: depth + 1) }
                case .mapping(let mapping):
                    var keys = Set<String>()
                    for (key, value) in mapping {
                        guard let name = key.string, keys.insert(name).inserted, !["__proto__", "constructor", "prototype"].contains(name) else { throw SubscriptionFailure("YAML 包含重复或不安全字段") }
                        try verify(value, depth: depth + 1)
                    }
                }
            }
            try verify(root, depth: 0); loaded = root.any
        } catch { throw SubscriptionFailure("源订阅不是有效或受支持的 Clash / Mihomo YAML") }
        guard let config = loaded as? [String: Any], let nodes = config["proxies"] as? [[String: Any]], !nodes.isEmpty, nodes.count <= 5000 else { throw SubscriptionFailure("源订阅需包含 1 至 5000 个内嵌 proxies 节点") }
        var names = Set<String>()
        for node in nodes {
            guard let name = node["name"] as? String, !name.isEmpty, name.count <= 256, let type = node["type"] as? String, !type.isEmpty, names.insert(name).inserted else { throw SubscriptionFailure("源订阅节点无效或重名") }
        }
        if let groups = config["proxy-groups"] { guard let list = groups as? [[String: Any]], list.allSatisfy({ $0["name"] is String }) else { throw SubscriptionFailure("源订阅代理组格式无效") } }
        if let rules = config["rules"], !(rules is [String]) { throw SubscriptionFailure("源订阅规则格式无效") }
        return config
    }
    static func fixedExit(_ raw: String) throws -> [String: Any] {
        guard raw.count <= 4096, !raw.contains(where: { $0.isWhitespace }), let c = URLComponents(string: raw), c.scheme == "vless", c.password == nil, let uuid = c.user, UUID(uuidString: uuid) != nil, let server = c.host, c.path.isEmpty || c.path == "/" else { throw SubscriptionFailure("固定出口需为有效 VLESS + WebSocket + TLS 链接") }
        let allowed: Set<String> = ["type", "security", "encryption", "sni", "host", "path", "fp", "alpn"]
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { guard allowed.contains(item.name), q[item.name] == nil, let value = item.value else { throw SubscriptionFailure("固定出口链接包含不支持或重复的参数") }; q[item.name] = value }
        guard q["type"] == "ws", q["security"] == "tls", q["encryption"] == nil || q["encryption"] == "none" else { throw SubscriptionFailure("仅支持 VLESS + WebSocket + TLS") }
        guard (1...65535).contains(c.port ?? 443) else { throw SubscriptionFailure("固定出口端口无效") }
        let sni = q["sni"] ?? server, host = q["host"] ?? sni, path = q["path"] ?? "/"
        for h in [server, sni, host] { let u = try publicURL("https://\(h)"); guard u.port == nil, u.host?.lowercased() == h.lowercased(), !h.contains("/") else { throw SubscriptionFailure("固定出口主机名无效") } }
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { throw SubscriptionFailure("WebSocket 路径无效") }
        var node: [String: Any] = ["type": "vless", "server": server, "port": c.port ?? 443, "uuid": uuid, "tls": true, "servername": sni, "network": "ws", "ws-opts": ["path": path, "headers": ["Host": host]]]
        if let fp = q["fp"] { guard ["chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"].contains(fp) else { throw SubscriptionFailure("不支持的指纹参数") }; node["client-fingerprint"] = fp }
        if let alpn = q["alpn"] { let values = alpn.components(separatedBy: ","); guard values.allSatisfy({ ["http/1.1", "h2"].contains($0) }) else { throw SubscriptionFailure("不支持的 ALPN") }; node["alpn"] = values }
        return node
    }
    static func validate(_ profile: SubscriptionProfile) throws {
        guard profile.client == nil || profile.isShadowrocket else { throw SubscriptionFailure("线路客户端无效") }
        if profile.isShadowrocket {
            guard profile.sourceUrl.isEmpty, profile.groups.count == 1, profile.groups[0].fixedExit != nil, profile.groups[0].nodes.isEmpty, profile.groups[0].chain == nil else { throw SubscriptionFailure("小火箭独立线路只需固定出口，前置请在手机中选择") }
            guard profile.rules.allSatisfy({ ClaudeRules.allowed(type: $0.type, value: $0.value) }) else { throw SubscriptionFailure("小火箭线路只支持 Claude 相关域名及推荐规则") }
        } else { _ = try publicURL(profile.sourceUrl) }
        guard !profile.name.trimmingCharacters(in: .whitespaces).isEmpty, profile.name.count <= 100, (1...10).contains(profile.groups.count), !profile.rules.isEmpty, profile.rules.count <= 100 else { throw SubscriptionFailure("请填写名称、代理组和域名规则") }
        let names = profile.groups.map(\.name)
        guard Set(names).count == names.count else { throw SubscriptionFailure("代理组名称不能重复") }
        for g in profile.groups {
            guard !g.name.isEmpty, g.name.count <= 100, !g.name.contains(","), !g.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), !reserved.contains(g.name.uppercased()), g.nodes.count <= 100, Set(g.nodes).count == g.nodes.count else { throw SubscriptionFailure("代理组名称或节点无效") }
            if let raw = g.fixedExit { _ = try fixedExit(raw) } else if g.nodes.isEmpty { throw SubscriptionFailure("请选择至少一个出口节点") }
            if let chain = g.chain { guard !chain.entry.isEmpty, !g.nodes.contains(chain.entry) else { throw SubscriptionFailure("请选择不同于出口的前置节点或代理组") } }
        }
        for r in profile.rules {
            guard names.contains(r.group), ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD"].contains(r.type), !r.value.isEmpty, r.value.count <= 253, r.value.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil else { throw SubscriptionFailure("请填写有效域名规则并选择代理组") }
        }
    }
    /// Fixed-exit front that url-tests every source node; keep in sync with AUTO_CHAIN_ENTRY in app/lib/fixed-exit.ts.
    static let autoChainEntry = "*"
    // ponytail: name heuristic for airport info pseudo-nodes, same list as app/lib/profile.ts.
    static func autoFrontNodes(_ proxies: [[String: Any]]) -> [String] {
        proxies.compactMap { p in
            guard p["dialer-proxy"] == nil, let name = p["name"] as? String,
                  name.range(of: "剩余|到期|过期|官网|流量|套餐|重置|expire|traffic|remaining", options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            return name
        }
    }
    static func transform(_ source: [String: Any], profile: SubscriptionProfile) throws -> String {
        try validate(profile)
        guard !profile.isShadowrocket else { throw SubscriptionFailure("小火箭独立线路请使用节点订阅和规则模块") }
        let proxies = source["proxies"] as? [[String: Any]] ?? []
        let originalGroups = source["proxy-groups"] as? [[String: Any]] ?? []
        let nodes = Dictionary(uniqueKeysWithValues: proxies.compactMap { p in (p["name"] as? String).map { ($0, p) } })
        let sourceGroups = Dictionary(originalGroups.compactMap { p in (p["name"] as? String).map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        var names = Set(nodes.keys).union(sourceGroups.keys)
        var additions: [[String: Any]] = [], groups: [[String: Any]] = [], extraGroups: [[String: Any]] = []
        for g in profile.groups { guard names.insert(g.name).inserted else { throw SubscriptionFailure("自定义代理组与原订阅重名：\(g.name)") } }
        func walk(_ name: String, active: Set<String>) throws -> Bool {
            if ["DIRECT", "REJECT", "REJECT-DROP"].contains(name) { return true }
            guard !active.contains(name) else { throw SubscriptionFailure("链式代理存在循环依赖") }
            let next = active.union([name])
            if let p = nodes[name] { if let entry = p["dialer-proxy"] as? String { return try walk(entry, active: next) }; return true }
            if let p = sourceGroups[name] {
                guard let children = p["proxies"] as? [String], !children.isEmpty, p["use"] == nil, p["include-all"] as? Bool != true, p["include-all-proxies"] as? Bool != true else { throw SubscriptionFailure("前置代理组需包含明确节点，暂不支持动态提供者") }
                for child in children { if try !walk(child, active: next) { return false } }; return true
            }
            return false
        }
        for g in profile.groups {
            var entries: [String] = []
            if let raw = g.fixedExit {
                let name = g.name + " · 固定出口"
                guard names.insert(name).inserted else { throw SubscriptionFailure("生成的固定出口名称重名") }
                if g.chain?.entry == autoChainEntry {
                    // Mirrors app/lib/profile.ts: explicit url-test list so the fixed exit never includes itself.
                    let hop = g.name + " · 前置跳板"
                    guard names.insert(hop).inserted else { throw SubscriptionFailure("生成的前置跳板名称重名") }
                    let members = autoFrontNodes(proxies)
                    if members.isEmpty { entries = ["REJECT"] }
                    else {
                        extraGroups.append(["name": hop, "type": "url-test", "proxies": members, "url": "https://www.gstatic.com/generate_204", "interval": 300, "tolerance": 50])
                        var node = try fixedExit(raw); node["name"] = name; node["dialer-proxy"] = hop; additions.append(node); entries = [name]
                    }
                } else if let chain = g.chain, try !walk(chain.entry, active: [g.name, name]) { entries = ["REJECT"] }
                else { var node = try fixedExit(raw); node["name"] = name; if let chain = g.chain { node["dialer-proxy"] = chain.entry }; additions.append(node); entries = [name] }
            } else {
                let missing = (g.nodes + (g.chain.map { [$0.entry] } ?? [])).contains { nodes[$0] == nil }
                if missing { entries = ["REJECT"] }
                else {
                    for (i, name) in g.nodes.enumerated() {
                        if let chain = g.chain {
                            guard var node = nodes[name], node["dialer-proxy"] == nil else { throw SubscriptionFailure("出口已有前置代理，不能覆盖") }
                            _ = try walk(chain.entry, active: Set(g.nodes).union([g.name]))
                            let generated = "\(g.name) · 链式出口 \(i + 1)"
                            guard names.insert(generated).inserted else { throw SubscriptionFailure("生成的链式出口名称重名") }
                            node["name"] = generated; node["dialer-proxy"] = chain.entry; additions.append(node); entries.append(generated)
                        } else { entries.append(name) }
                    }
                }
            }
            groups.append(["name": g.name, "type": "select", "proxies": entries])
        }
        let fixed = Set(profile.groups.filter { $0.fixedExit != nil }.map(\.name))
        let rules = profile.rules.flatMap { r -> [String] in
            let route = "\(r.type),\(r.value.lowercased()),\(r.group)"
            return fixed.contains(r.group) ? ["AND,((\(r.type),\(r.value.lowercased())),(NETWORK,UDP)),REJECT", route] : [route]
        }
        var output = source; output["mode"] = "rule"; output["proxies"] = proxies + additions; output["proxy-groups"] = originalGroups + groups + extraGroups; output["rules"] = rules + (source["rules"] as? [String] ?? [])
        return try Yams.dump(object: output, width: -1)
    }
}
