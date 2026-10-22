import XCTest
@testable import SubscriptionStudio

final class AccountUsageTests: XCTestCase {
    func testParsesWindowsAndPicksChatOrganization() throws {
        let usage = try XCTUnwrap(AccountUsageParser.parse(Data(#"{"five_hour":{"utilization":42.5,"resets_at":"2026-10-21T10:00:00.123456+00:00"},"seven_day":{"utilization":130,"resets_at":null},"seven_day_opus":null}"#.utf8)))
        XCTAssertEqual(usage.fiveHour?.percent, 42.5); XCTAssertNotNil(usage.fiveHour?.resetsAt)
        XCTAssertEqual(usage.sevenDay?.percent, 100); XCTAssertNil(usage.sevenDay?.resetsAt)
        XCTAssertEqual(usage.highest, 100)
        XCTAssertNil(AccountUsageParser.parse(Data(#"{"error":"x"}"#.utf8)))
        XCTAssertNil(usage.models)
    }
    func testModelScopedWeeklyLimits() throws {
        let body = #"{"seven_day":{"utilization":10},"seven_day_opus":{"utilization":20},"seven_day_sonnet":{"utilization":5},"limits":[{"kind":"weekly_scoped","group":"weekly","percent":95,"resets_at":"2026-10-25T00:00:00Z","scope":{"model":{"display_name":"Opus"}}},{"kind":"weekly_scoped","group":"weekly","percent":70,"scope":{"model":{"display_name":"fable"}}},{"kind":"weekly_scoped","group":"weekly","percent":99,"scope":{"surface":"code","model":{"display_name":"Sonnet"}}},{"kind":"session","group":"weekly","percent":50,"scope":{"model":{"display_name":"Sonnet"}}}]}"#
        let usage = try XCTUnwrap(AccountUsageParser.parse(Data(body.utf8)))
        XCTAssertEqual(usage.models?["Opus"]?.percent, 95); XCTAssertNotNil(usage.models?["Opus"]?.resetsAt)
        XCTAssertEqual(usage.models?["Fable"]?.percent, 70)
        XCTAssertEqual(usage.models?["Sonnet"]?.percent, 5)  // surface-scoped and non-weekly entries ignored
        XCTAssertEqual(usage.highest, 95)
        XCTAssertEqual(usage.sortedModels.map(\.name), ["Fable", "Opus", "Sonnet"])
        let account = #"{"memberships":[{"organization":{"uuid":"11111111-1111-1111-1111-111111111111","capabilities":["api"]}},{"organization":{"uuid":"22222222-2222-2222-2222-222222222222","capabilities":["chat"]}}]}"#
        XCTAssertEqual(AccountUsageParser.organizationID(Data(account.utf8)), "22222222-2222-2222-2222-222222222222")
        XCTAssertNil(AccountUsageParser.organizationID(Data(#"{"memberships":[{"organization":{"uuid":"x'); alert(1);//","capabilities":["chat"]}}]}"#.utf8)))
    }
}
