import XCTest
@testable import SubscriptionStudio

final class LineEngineTests: XCTestCase {
    func testConfigKeepsOnlyTheChainAndRoutesEverythingThroughIt() throws {
        let yaml = """
        port: 7890
        external-controller: 127.0.0.1:9090
        tun: { enable: true }
        proxies:
          - { name: HK, type: ss, server: hk.example.com, port: 443, cipher: aes-128-gcm, password: p }
          - { name: JP, type: ss, server: jp.example.com, port: 443, cipher: aes-128-gcm, password: p }
          - { name: Claude 固定节点 · 固定出口, type: socks5, server: 1.2.3.4, port: 1080, dialer-proxy: 前置 }
        proxy-groups:
          - { name: 前置, type: select, proxies: [HK, DIRECT] }
          - { name: Claude 固定节点, type: select, proxies: [Claude 固定节点 · 固定出口] }
          - { name: 其他, type: select, proxies: [JP] }
        rules: [GEOIP,CN,DIRECT, MATCH,其他]
        """
        let config = try LineEngine.config(yaml: yaml, group: "Claude 固定节点", socket: "/tmp/x.sock", secret: "s")
        XCTAssertEqual(Set((config["proxies"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }), ["HK", "Claude 固定节点 · 固定出口"])
        let groups = config["proxy-groups"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(groups.compactMap { $0["name"] as? String }), ["前置", "Claude 固定节点", LineEngine.gate])
        // Every request passes the gate, which starts closed (REJECT first) until the exit is verified.
        XCTAssertEqual(config["rules"] as? [String], ["NETWORK,UDP,REJECT", "MATCH,\(LineEngine.gate)"])
        XCTAssertEqual(groups.first { $0["name"] as? String == LineEngine.gate }?["proxies"] as? [String], ["REJECT", "Claude 固定节点"])
        // The probe listener bypasses the gate so a blocked line can still be re-verified.
        let probe = (config["listeners"] as? [[String: Any]])?.first
        XCTAssertEqual(probe?["proxy"] as? String, "Claude 固定节点")
        XCTAssertEqual(probe?["port"] as? Int, LineEngine.probePort)
        XCTAssertEqual(probe?["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(config["mixed-port"] as? Int, LineEngine.port)
        XCTAssertEqual(config["bind-address"] as? String, "127.0.0.1")
        XCTAssertEqual(config["external-controller"] as? String, "")
        XCTAssertEqual((config["tun"] as? [String: Any])?["enable"] as? Bool, false)
    }

    func testConfigRejectsMissingNodesAndProviderGroups() {
        XCTAssertThrowsError(try LineEngine.config(yaml: "proxy-groups: [{ name: G, type: select, proxies: [Gone] }]", group: "G", socket: "s", secret: "s"))
        XCTAssertThrowsError(try LineEngine.config(yaml: "proxy-groups: [{ name: G, type: select, use: [p] }]", group: "G", socket: "s", secret: "s"))
        XCTAssertThrowsError(try LineEngine.config(yaml: "proxies: []", group: "G", socket: "s", secret: "s"))
    }

    func testGateOpensOnlyForMarkedExit() {
        XCTAssertTrue(LineEngine.gateDecision(exit: "107.191.58.141", marked: "107.191.58.141").open)
        XCTAssertFalse(LineEngine.gateDecision(exit: "107.191.58.142", marked: "107.191.58.141").open)
        XCTAssertFalse(LineEngine.gateDecision(exit: "107.191.58.141", marked: nil).open)
        XCTAssertFalse(LineEngine.gateDecision(exit: nil, marked: "107.191.58.141").open)
        XCTAssertFalse(LineEngine.gateDecision(exit: "not-an-ip", marked: "107.191.58.141").open)
    }

    func testLineGroupFollowsClaudeRule() {
        var profile = SubscriptionProfile.empty
        profile.groups.insert(.init(name: "其他", nodes: ["JP"]), at: 0)
        XCTAssertEqual(SubscriptionModel.lineGroup(profile), "Claude 固定节点")
    }
}
