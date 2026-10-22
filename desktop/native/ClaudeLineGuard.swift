import Foundation

/// Runtime-independent gate. All calls and relay cancellation run on the same
/// actor; the extension adapter must supply trusted probe evidence and a
/// monotonic timestamp. No stored evidence survives process restart.
@MainActor final class ClaudeLineGuard {
    struct Event: Equatable {
        let host: String
        let reason: String
    }
    private(set) var generation = UUID()
    private(set) var events: [Event] = []
    private(set) var blockedCount = 0
    private var routeID = ""
    private var engineReady = false
    private var evidence: ClaudeLinePolicy.Evidence?
    private var connections: [UUID: () -> Void] = [:]
    var activeCount: Int { connections.count }

    func configure(routeID: String) {
        invalidate(reason: "线路配置已变更")
        self.routeID = routeID
        generation = UUID()
        engineReady = false
    }
    func setEngineReady(_ ready: Bool) {
        if !ready { invalidate(reason: "专线引擎不可用") }
        engineReady = ready
    }
    @discardableResult func acceptProbe(_ proof: ClaudeLinePolicy.Evidence, now: TimeInterval) -> Bool {
        let result = ClaudeLinePolicy.decide(host: "claude.ai", udp: false,
            engineReady: engineReady, routeID: routeID, generation: generation,
            evidence: proof, now: now)
        guard result == .tunnel else {
            invalidate(reason: "出口核验未通过")
            return false
        }
        evidence = proof
        return true
    }
    func checkLease(now: TimeInterval) {
        guard evidence != nil else { return }
        if decision(host: "claude.ai", now: now) != .tunnel {
            invalidate(reason: "出口核验已失效")
        }
    }
    func decision(host: String?, udp: Bool = false, now: TimeInterval) -> ClaudeLinePolicy.Decision {
        ClaudeLinePolicy.decide(host: host, udp: udp, engineReady: engineReady,
            routeID: routeID, generation: generation, evidence: evidence, now: now)
    }
    /// Register cancellation before beginning relay IO. nil means do not relay.
    func admit(host: String, now: TimeInterval, cancel: @escaping () -> Void) -> UUID? {
        let result = decision(host: host, now: now)
        guard result == .tunnel else {
            if case .block(let reason) = result {
                blockedCount += 1
                record(host: host, reason: reason)
            }
            return nil
        }
        let id = UUID()
        connections[id] = cancel
        return id
    }
    func finished(_ id: UUID) { connections.removeValue(forKey: id) }
    func invalidate(reason: String) {
        evidence = nil
        let pending = Array(connections.values)
        connections.removeAll()
        pending.forEach { $0() }
        // Never accept upstream error strings here: they may contain credentials.
        record(host: "", reason: reason)
    }
    private func record(host: String, reason: String) {
        // Retain only recognized hostname labels; never persist URLs or payloads.
        let safeHost = ClaudeLinePolicy.isClaude(host) && host.utf8.count <= 253
            && host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }
            ? host.lowercased() : ""
        let event = Event(host: safeHost, reason: reason)
        guard events.last != event else { return }
        events.append(event)
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
}
