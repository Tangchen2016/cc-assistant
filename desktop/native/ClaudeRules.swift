import Foundation

/// Domains that keep Claude, and the third-party services its pages load, on the dedicated exit.
/// From a community Surge list (2026-04-10) minus IP rules (this app models domain rules only),
/// the over-broad `DOMAIN-KEYWORD,datadoghq` and bulk `storage.googleapis.com` downloads.
/// Keep in sync with app/lib/claude-rules.ts.
enum ClaudeRules {
    static let ownedRoots = ["claude.ai", "anthropic.com", "claude.com", "clau.de", "claudeusercontent.com", "claudemcpclient.com"]
    static let keywords = ["claude", "anthropic"]
    static let recommended: [(type: String, value: String)] = ownedRoots.map { ("DOMAIN-SUFFIX", $0) } + [
        ("DOMAIN", "servd-anthropic-website.b-cdn.net"), ("DOMAIN", "anthropic.com.cdn.cloudflare.net"), ("DOMAIN", "cdn.usefathom.com"),
        ("DOMAIN", "anthropic.auth0.com"), ("DOMAIN", "anthropic-com.ghost.io"),
        ("DOMAIN", "browser-intake-us5-datadoghq.com"),
        ("DOMAIN-SUFFIX", "intercom.io"), ("DOMAIN-SUFFIX", "intercomcdn.com"),
        ("DOMAIN-SUFFIX", "statsigapi.net"), ("DOMAIN-SUFFIX", "sentry.io"),
        ("DOMAIN-KEYWORD", "sift"),
        ("DOMAIN", "t0.gstatic.com"), ("DOMAIN", "t1.gstatic.com"), ("DOMAIN", "t2.gstatic.com"), ("DOMAIN", "t3.gstatic.com"),
    ] + keywords.map { ("DOMAIN-KEYWORD", $0) }

    /// One concrete host per recommended rule, used to verify which route each actually takes.
    /// (claudemcpclient.com is omitted: the bare domain has no DNS record, only its subdomains are used.)
    /// `trace`: Cloudflare-fronted, so /cdn-cgi/trace reveals the real exit IP.
    static let probes: [(host: String, purpose: String, trace: Bool)] = [
        ("claude.ai", "Claude 网页", true), ("anthropic.com", "Anthropic 官网", true), ("claude.com", "Claude 官网", true),
        ("clau.de", "短链接", true), ("claudeusercontent.com", "Artifacts 内容", true),
        ("servd-anthropic-website.b-cdn.net", "官网 CDN", false), ("cdn.usefathom.com", "访问统计", false),
        ("anthropic.auth0.com", "登录认证", true), ("anthropic-com.ghost.io", "博客内容", false),
        ("browser-intake-us5-datadoghq.com", "Datadog 遥测", false), ("api-iam.intercom.io", "Intercom 客服", false),
        ("js.intercomcdn.com", "Intercom 资源", false), ("statsigapi.net", "Statsig 功能开关", false),
        ("sentry.io", "Sentry 错误上报", false), ("cdn.sift.com", "Sift 反欺诈", false), ("t0.gstatic.com", "Google 图标", false),
    ]

    /// Mobile modules stay keyword-free so a phone module can never grow beyond listed domains.
    static func rules(group: String, mobile: Bool = false) -> [SubscriptionRule] {
        recommended.filter { !mobile || $0.type != "DOMAIN-KEYWORD" }.map { .init(type: $0.type, value: $0.value, group: group) }
    }

    /// Allowed on Shadowrocket lines: an Anthropic-owned domain or an exact recommended domain entry; never a keyword.
    static func allowed(type: String, value: String) -> Bool {
        guard type != "DOMAIN-KEYWORD" else { return false }
        let value = value.lowercased()
        return recommended.contains { $0.type == type && $0.value == value } || ownedRoots.contains { value == $0 || value.hasSuffix("." + $0) }
    }

    /// Whether a host is Anthropic's own (owned root or keyword); used to flag Claude traffic off the line.
    static func isClaudeHost(_ hostPort: String) -> Bool {
        let host = hostPort.split(separator: ":").first.map { $0.lowercased() } ?? hostPort.lowercased()
        return ownedRoots.contains { host == $0 || host.hasSuffix("." + $0) } || keywords.contains { host.contains($0) }
    }

    /// Whether a host is covered by the recommended list at all.
    static func covers(_ hostPort: String) -> Bool {
        let host = hostPort.split(separator: ":").first.map { $0.lowercased() } ?? hostPort.lowercased()
        return recommended.contains { rule in
            switch rule.type {
            case "DOMAIN": return host == rule.value
            case "DOMAIN-KEYWORD": return host.contains(rule.value)
            default: return host == rule.value || host.hasSuffix("." + rule.value)
            }
        }
    }
}
