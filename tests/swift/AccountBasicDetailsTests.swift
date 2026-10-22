import XCTest
@testable import SubscriptionStudio

final class AccountBasicDetailsTests: XCTestCase {
    func testBasicFieldsAndAllOrganizationsAreParsed() throws {
        let json = #"{"email_address":"fixture@example.invalid","full_name":"Example","display_name":"Display","created_at":"2024-01-02T03:04:05.123456Z","updated_at":"2026-01-02T03:04:05Z","completed_verification_at":"2024-01-02T03:05:05Z","is_verified":true,"onboarding_complete":false,"memberships":[{"role":"owner","seat_tier":"team_standard","organization":{"uuid":"org-one","name":"Example org","analytics_subscription_plan":"claude_pro","plan_display_name":"Pro","billing_issue":null,"access_block":false,"subscription_pause":{"reason":"example"}}},{"role":"member","organization":{"uuid":"org-two","name":"Another org"}}]}"#
        let identity = try AccountIdentityParser.parse(Data(json.utf8))
        XCTAssertNotNil(identity.remoteCreatedAt); XCTAssertEqual(identity.name, "Example")
        let details = try XCTUnwrap(identity.details)
        XCTAssertEqual(details.displayName, "Display"); XCTAssertEqual(details.verified, true); XCTAssertEqual(details.onboardingComplete, false)
        XCTAssertNotNil(details.verificationCompletedAt); XCTAssertNotNil(details.remoteUpdatedAt)
        XCTAssertEqual(details.organizations.count, 2); XCTAssertEqual(details.organizations[0].role, "owner")
        XCTAssertEqual(details.organizations[0].billingIssue, "官网未报告")
        XCTAssertEqual(details.organizations[0].accessBlock, "官网返回 false")
        XCTAssertEqual(details.organizations[0].subscriptionPause, "官网返回结构化信息，需进一步核对")
        XCTAssertNil(identity.plan)
    }
    func testMissingAndMalformedFlagsStayUnknownAndLegacyDecodes() throws {
        let identity = try AccountIdentityParser.parse(Data(#"{"email_address":"fixture@example.invalid","is_verified":1,"onboarding_complete":"true"}"#.utf8))
        XCTAssertNil(identity.details?.verified); XCTAssertNil(identity.details?.onboardingComplete)
        XCTAssertNil(identity.remoteCreatedAt)
        let legacy = #"{"email":"fixture@example.invalid","planIsInferred":false,"checkedAt":100}"#
        XCTAssertNil(try JSONDecoder().decode(AccountIdentitySnapshot.self, from: Data(legacy.utf8)).details)
    }
    @MainActor func testRegistrationAndRecordedDatesStaySeparateAcrossRefreshAndEdit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AccountPoolStore(fileURL: dir.appendingPathComponent("accounts.json"))
        let saved = try store.save(.init(email: "fixture@example.invalid"), now: Date(timeIntervalSince1970: 1_800_000_000))
        let identity = try AccountIdentityParser.parse(Data(#"{"email_address":"fixture@example.invalid","created_at":"2024-01-02T03:04:05Z","display_name":"Name"}"#.utf8))
        let refreshed = try store.acceptIdentity(identity, targetID: saved.id)
        XCTAssertEqual(refreshed.recordedAt, saved.recordedAt); XCTAssertEqual(refreshed.createdAt, saved.createdAt)
        XCTAssertNotEqual(refreshed.recordedAt, identity.remoteCreatedAt)
        let edited = try store.save(refreshed.draft, id: refreshed.id)
        XCTAssertEqual(edited.identity?.details?.displayName, "Name"); XCTAssertEqual(edited.recordedAt, saved.recordedAt)
        let reloaded = AccountPoolStore(fileURL: store.fileURL)
        XCTAssertNil(reloaded.loadError); XCTAssertEqual(reloaded.records[0].identity?.details, edited.identity?.details)
    }
}
