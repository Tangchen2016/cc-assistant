import XCTest
@testable import SubscriptionStudio

final class AccountPlanParsingTests: XCTestCase {
    private func parse(_ organization: [String: Any], extra: [String: Any] = [:]) throws -> AccountIdentitySnapshot {
        var account: [String: Any] = ["email_address": "fixture@example.invalid", "memberships": [["organization": organization]]]
        account.merge(extra) { _, new in new }
        return try AccountIdentityParser.parse(JSONSerialization.data(withJSONObject: account))
    }
    func testAnalyticsPlanOverridesFallbackAndUnknownDoesNotBecomeFree() throws {
        for (raw, expected) in [("claude_free", "Free"), ("claude_pro", "Pro"), ("claude_max", "Max"), ("claude_team", "Team"), ("claude_enterprise", "Enterprise")] {
            let value = try parse(["analytics_subscription_plan": raw, "rate_limit_tier": "default_claude_ai", "capabilities": ["chat"], "billing_type": NSNull()])
            XCTAssertEqual(value.plan, expected); XCTAssertFalse(value.planIsInferred)
        }
        XCTAssertNil(try parse(["analytics_subscription_plan": "claude_future", "rate_limit_tier": "default_claude_ai", "capabilities": ["chat"], "billing_type": NSNull()]).plan)
        let conflict = try parse(["analytics_subscription_plan": "claude_pro"], extra: ["subscription_type": "free"])
        XCTAssertEqual(conflict.plan, "Pro"); XCTAssertFalse(conflict.planIsInferred)
    }
    func testObservedFreeShapeAndIncompleteBillingEvidence() throws {
        let org: [String: Any] = ["rate_limit_tier": "default_claude_ai", "capabilities": ["chat"], "billing_type": NSNull()]
        let value = try parse(org)
        XCTAssertEqual(value.plan, "Free"); XCTAssertTrue(value.planIsInferred)
        var changed = org; changed.removeValue(forKey: "billing_type")
        XCTAssertNil(try parse(changed).plan)
        changed = org; changed["billing_type"] = "stripe_subscription"
        XCTAssertNil(try parse(changed).plan)
        XCTAssertNil(try parse(org, extra: ["has_claude_max": true]).plan)
    }
    func testPaidTiersAndCapabilityHints() throws {
        for (tier, label) in [("default_claude_pro", "Pro"), ("default_claude_max_5x", "Max 5x"), ("default_claude_max_20x", "Max 20x"), ("default_claude_team", "Team"), ("default_claude_enterprise", "Enterprise")] {
            let value = try parse(["rate_limit_tier": tier]); XCTAssertEqual(value.plan, label); XCTAssertTrue(value.planIsInferred)
        }
        XCTAssertEqual(try parse(["capabilities": ["chat", "claude_pro"]]).plan, "Pro")
        XCTAssertEqual(try parse(["organization_type": "claude_team"]).plan, "Team")
        XCTAssertNil(try parse(["organization_type": "claude_team", "rate_limit_tier": "default_claude_max_5x"]).plan)
        XCTAssertNil(try parse(["rate_limit_tier": "default_claude_unknown"]).plan)
    }
    func testExplicitPlanPrecedenceAndMultipleOrganizations() throws {
        let value = try parse(["rate_limit_tier": "default_claude_max_5x"], extra: ["subscription_type": "pro"])
        XCTAssertEqual(value.plan, "Pro"); XCTAssertFalse(value.planIsInferred)
        XCTAssertEqual(try parse(["subscription_type": "claude_enterprise"]).plan, "Enterprise")
        XCTAssertNil(try parse(["rate_limit_tier": "default_claude_pro"], extra: ["subscription_type": "unknown_new_plan"]).plan)
        let multiple: [String: Any] = ["memberships": [["organization": ["rate_limit_tier": "default_claude_pro"]], ["organization": ["rate_limit_tier": "default_claude_max_5x"]]]]
        XCTAssertNil(try parse([:], extra: multiple).plan)
    }
}
