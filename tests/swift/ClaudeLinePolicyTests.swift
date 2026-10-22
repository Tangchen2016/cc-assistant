import XCTest
@testable import SubscriptionStudio

final class ClaudeLinePolicyTests: XCTestCase {
    func testDomainBoundaries() {
        for host in ["claude.ai", "ASSETS-PROXY.ANTHROPIC.COM.", "platform.claude.com"] {
            XCTAssertTrue(ClaudeLinePolicy.isClaude(host))
        }
        for host in ["evilclaude.ai", "claude.ai.evil.com", "claude.ai@evil.com", ""] {
            XCTAssertFalse(ClaudeLinePolicy.isClaude(host))
        }
    }
    func testFailClosedLeaseAndRouteBinding() {
        let generation = UUID()
        var proof = ClaudeLinePolicy.Evidence(routeID: "r1", generation: generation,
            expectedIP: "203.0.113.1", observedIP: "203.0.113.1", checkedAt: 100)
        func decision(_ evidence: ClaudeLinePolicy.Evidence?, time: Double = 110,
                      ready: Bool = true, udp: Bool = false, host: String? = "claude.ai") -> ClaudeLinePolicy.Decision {
            ClaudeLinePolicy.decide(host: host, udp: udp, engineReady: ready,
                routeID: "r1", generation: generation, evidence: evidence, now: time)
        }
        XCTAssertEqual(decision(proof), .tunnel)
        XCTAssertEqual(decision(nil, ready: false, host: "example.com"), .system)
        XCTAssertEqual(decision(proof, host: nil), .unclassified)
        XCTAssertEqual(decision(proof, host: "1.2.3.4"), .unclassified)
        for result in [decision(nil), decision(proof, time: 131), decision(proof, time: 99),
                       decision(proof, ready: false), decision(proof, udp: true), decision(proof, time: .nan)] {
            guard case .block = result else { return XCTFail("Unsafe route permitted: \(result)") }
        }
        proof.observedIP = "203.0.113.2"
        guard case .block = decision(proof) else { return XCTFail("IP drift allowed") }
        proof.observedIP = proof.expectedIP; proof.generation = UUID()
        guard case .block = decision(proof) else { return XCTFail("Old engine proof reused") }
        proof.generation = generation; proof.routeID = "r2"
        guard case .block = decision(proof) else { return XCTFail("Different route proof reused") }
    }
    func testIPNormalization() {
        XCTAssertEqual(ClaudeLinePolicy.canonicalIP("2001:db8:0:0:0:0:0:1"), "2001:db8::1")
        XCTAssertNil(ClaudeLinePolicy.canonicalIP("999.1.1.1"))
    }
}

final class ClaudeLineGuardTests: XCTestCase {
    @MainActor func testRevocationClosesExistingStreamsAndRejectsNewOnes() {
        let guardState = ClaudeLineGuard()
        guardState.configure(routeID: "r1")
        guardState.setEngineReady(true)
        let proof = ClaudeLinePolicy.Evidence(routeID: "r1", generation: guardState.generation,
            expectedIP: "203.0.113.1", observedIP: "203.0.113.1", checkedAt: 100)
        XCTAssertTrue(guardState.acceptProbe(proof, now: 100))
        var closed = 0
        XCTAssertNotNil(guardState.admit(host: "claude.ai", now: 101) { closed += 1 })
        guardState.checkLease(now: 131)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(guardState.activeCount, 0)
        XCTAssertNil(guardState.admit(host: "claude.ai", now: 132) { closed += 1 })
        XCTAssertEqual(guardState.blockedCount, 1)
        guardState.checkLease(now: 132)
        XCTAssertEqual(closed, 1)
    }
    @MainActor func testProbeFailureRevokesAndNewConfigurationRejectsOldProof() {
        let guardState = ClaudeLineGuard()
        guardState.configure(routeID: "r1"); guardState.setEngineReady(true)
        var proof = ClaudeLinePolicy.Evidence(routeID: "r1", generation: guardState.generation,
            expectedIP: "203.0.113.1", observedIP: "203.0.113.1", checkedAt: 100)
        XCTAssertTrue(guardState.acceptProbe(proof, now: 100))
        var closed = false
        XCTAssertNotNil(guardState.admit(host: "api.anthropic.com", now: 101) { closed = true })
        proof.observedIP = "203.0.113.2"
        XCTAssertFalse(guardState.acceptProbe(proof, now: 102))
        XCTAssertTrue(closed)
        guardState.configure(routeID: "r1"); guardState.setEngineReady(true)
        proof.observedIP = proof.expectedIP
        XCTAssertFalse(guardState.acceptProbe(proof, now: 103))
    }
}
