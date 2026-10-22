import XCTest
@testable import SubscriptionStudio

final class WorkspaceWiringTests: XCTestCase {
    /// Guards the cross-model wiring: losing it compiles fine but breaks the browser probe and account flows.
    @MainActor func testWorkspaceWiresBrowserAndAccountCallbacks() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = AccountPoolModel()
        let model = WorkspaceModel(subscriptions: SubscriptionModel(storage: SubscriptionStorage(directory: root)), updates: AppUpdates { false }, accounts: accounts)
        XCTAssertNotNil(accounts.connectionFlow.prepareBrowser)
        XCTAssertNotNil(accounts.connectionFlow.openBrowser)
        XCTAssertNotNil(accounts.connectionFlow.browserReader)
        XCTAssertNotNil(accounts.readAccountBrowser)
        XCTAssertNotNil(accounts.accountSessionProxy)
    }
}
