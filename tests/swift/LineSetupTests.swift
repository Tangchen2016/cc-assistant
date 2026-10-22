import XCTest
@testable import SubscriptionStudio

final class LineSetupTests: XCTestCase {
    @MainActor func testChainCanOnlyBeEnabledForStaticExitAndSwitchingBackClearsIt() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SubscriptionModel(storage: SubscriptionStorage(directory: root))
        model.stage = "configure"
        model.profile.groups[0].nodes = ["HK"]
        let rules = model.profile.rules
        model.setChainEnabled(true)
        XCTAssertNil(model.profile.groups[0].chain)
        model.setExitSource(true)
        model.setChainEnabled(true)
        XCTAssertNotNil(model.profile.groups[0].chain)
        model.profile.groups[0].chain?.entry = "General"
        model.setChainEnabled(true)
        XCTAssertEqual(model.profile.groups[0].chain?.entry, "General")
        model.setExitSource(false)
        XCTAssertNil(model.profile.groups[0].chain)
        XCTAssertNil(model.profile.groups[0].fixedExit)
        XCTAssertNil(model.profile.groups[0].staticNodeId)
        XCTAssertEqual(model.profile.groups[0].nodes, ["HK"])
        XCTAssertEqual(model.profile.rules, rules)
    }
    @MainActor func testEditorRejectsLegacySubscriptionChainWithoutSilentlyChangingIt() {
        var profile = SubscriptionProfile.empty
        profile.groups[0].chain = .init(entry: "HK")
        XCTAssertThrowsError(try SubscriptionModel.validateEditorSetup(profile))
        XCTAssertEqual(profile.groups[0].chain?.entry, "HK")
        profile.groups[0].fixedExit = "vless://example"
        XCTAssertNoThrow(try SubscriptionModel.validateEditorSetup(profile))
        profile.groups[0].chain = nil
        profile.groups[0].fixedExit = nil
        XCTAssertNoThrow(try SubscriptionModel.validateEditorSetup(profile))
    }
}
