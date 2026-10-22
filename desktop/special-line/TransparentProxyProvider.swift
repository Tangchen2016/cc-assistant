import Foundation
import NetworkExtension

/// Deliberately deny-only prototype. Do not embed or activate in a release until
/// authenticated IPC, same-route probes, TCP relay and revocation are implemented.
final class TransparentProxyProvider: NETransparentProxyProvider {
    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Fail startup before installing any network rules. A partially implemented
        // provider must never leave the host claiming it protects the machine.
        completionHandler(NSError(domain: "CCAssistant.SpecialLine", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "透明代理转发与链路核验尚未接入，禁止启用"]))
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let host = flow.remoteHostname, ClaudeLinePolicy.isClaude(host) else {
            // false means OS handling for a transparent proxy, not a forced DIRECT route.
            // Unknown hosts are unclassified, not evidence of non-Claude traffic.
            return false
        }
        let error = NSError(domain: "CCAssistant.SpecialLine", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Claude 专线尚未通过链路核验"])
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        return true
    }
}
