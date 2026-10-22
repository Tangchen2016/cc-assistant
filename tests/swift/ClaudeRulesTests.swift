import XCTest
@testable import SubscriptionStudio

final class ClaudeRulesTests: XCTestCase {
    func testNewLinesStartWithRecommendedRules() throws {
        let profile = SubscriptionProfile.empty
        XCTAssertEqual(profile.rules.count, ClaudeRules.recommended.count)
        XCTAssertTrue(profile.rules.contains { $0.type == "DOMAIN-SUFFIX" && $0.value == "claudeusercontent.com" })
        XCTAssertTrue(profile.rules.contains { $0.type == "DOMAIN-KEYWORD" && $0.value == "sift" })
        XCTAssertFalse(profile.rules.contains { $0.value == "storage.googleapis.com" || $0.value == "datadoghq" })
    }

    func testShadowrocketAllowsOwnedDomainsAndRecommendedEntriesOnly() {
        XCTAssertTrue(ClaudeRules.allowed(type: "DOMAIN-SUFFIX", value: "api.anthropic.com"))
        XCTAssertTrue(ClaudeRules.allowed(type: "DOMAIN-SUFFIX", value: "statsigapi.net"))
        XCTAssertFalse(ClaudeRules.allowed(type: "DOMAIN-KEYWORD", value: "sift"))  // phone modules stay keyword-free
        XCTAssertFalse(ClaudeRules.allowed(type: "DOMAIN-KEYWORD", value: "claude"))
        XCTAssertFalse(ClaudeRules.allowed(type: "DOMAIN-KEYWORD", value: "google"))
        XCTAssertFalse(ClaudeRules.allowed(type: "DOMAIN-SUFFIX", value: "example.com"))
        var mobile = SubscriptionProfile.mobile
        mobile.groups[0].fixedExit = "vless://00000000-0000-0000-0000-000000000000@exit.example.com:443?type=ws&security=tls"
        XCTAssertFalse(mobile.rules.contains { $0.type == "DOMAIN-KEYWORD" })
        mobile.rules = ClaudeRules.rules(group: mobile.groups[0].name, mobile: true)
        XCTAssertNoThrow(try SubscriptionCore.validate(mobile))
    }

    func testCoverageMatchesRealHosts() {
        XCTAssertTrue(ClaudeRules.covers("48927f2e-21c4-4857-83ab.claudeusercontent.com:443"))
        XCTAssertTrue(ClaudeRules.covers("cdn.sift.com:443"))
        XCTAssertTrue(ClaudeRules.covers("t2.gstatic.com:443"))
        XCTAssertFalse(ClaudeRules.covers("www.gstatic.com:443"))
        XCTAssertFalse(ClaudeRules.covers("ws.chatgpt.com:443"))
    }
}
