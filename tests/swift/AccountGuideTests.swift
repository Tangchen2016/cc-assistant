import XCTest
@testable import SubscriptionStudio

final class AccountGuideTests: XCTestCase {
    func testLegacyRoutesKeepTheirGuideSection() {
        XCTAssertEqual(AccountGuideSection.forRoute("registration"), .registration)
        XCTAssertEqual(AccountGuideSection.forRoute("domain"), .registration)
        XCTAssertEqual(AccountGuideSection.forRoute("email"), .registration)
        XCTAssertEqual(AccountGuideSection.forRoute("payment"), .payment)
        XCTAssertEqual(AccountGuideSection.forRoute("usage"), .usage)
        XCTAssertNil(AccountGuideSection.forRoute("browser"))
        XCTAssertNil(AccountGuideSection.forRoute("guide"))
    }
    @MainActor func testSelectedGuideSectionIsRetainedAndInvalidStateIsSafe() throws {
        let name = "cc-guide-test-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AccountGuideNavigation(defaults: defaults)
        XCTAssertEqual(model.section, .registration)
        model.section = .payment
        XCTAssertEqual(AccountGuideNavigation(defaults: defaults).section, .payment)
        model.section = .usage
        XCTAssertEqual(AccountGuideNavigation(defaults: defaults).section, .usage)
        defaults.set("invalid", forKey: "accountGuideSection")
        XCTAssertEqual(AccountGuideNavigation(defaults: defaults).section, .registration)
    }
}
