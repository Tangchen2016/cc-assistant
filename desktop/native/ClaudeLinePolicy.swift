import Foundation
import Darwin

/// Shared with the transparent extension. A successful probe is a short lease,
/// scoped to an exact engine generation and route, never a global safety flag.
struct ClaudeLinePolicy {
    static let domains = ["anthropic.com", "claude.ai", "claude.com", "claudeusercontent.com"]
    enum Decision: Equatable {
        case system
        case unclassified
        case tunnel
        case block(String)
    }
    struct Evidence {
        var routeID: String
        var generation: UUID
        var expectedIP: String
        var observedIP: String
        var checkedAt: TimeInterval
    }
    static func isClaude(_ raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static func canonicalIP(_ raw: String) -> String? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var v4 = in_addr(), v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, input, &v4) == 1 {
            guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        } else if inet_pton(AF_INET6, input, &v6) == 1 {
            guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        } else { return nil }
        return String(cString: buffer)
    }
    static func decide(host: String?, udp: Bool, engineReady: Bool, routeID: String,
                       generation: UUID, evidence: Evidence?, now: TimeInterval) -> Decision {
        guard let host, !host.isEmpty, canonicalIP(host) == nil else { return .unclassified }
        guard isClaude(host) else { return .system }
        guard !udp else { return .block("Claude UDP 尚未接入固定出口") }
        guard engineReady else { return .block("专线引擎未就绪") }
        guard let evidence else { return .block("等待出口核验") }
        guard !routeID.isEmpty, evidence.routeID == routeID, evidence.generation == generation else {
            return .block("线路已变更，需要重新核验")
        }
        let age = now - evidence.checkedAt
        guard age.isFinite, age >= 0, age <= 30 else { return .block("出口核验已失效") }
        guard let expected = canonicalIP(evidence.expectedIP),
              let observed = canonicalIP(evidence.observedIP), expected == observed else {
            return .block("出口 IP 与标记不一致")
        }
        return .tunnel
    }
}
