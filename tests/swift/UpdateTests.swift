import XCTest
import Sparkle
@testable import SubscriptionStudio

final class UpdateTests: XCTestCase {
    @MainActor func testReadyUpdateCannotInstallBeforeUserRequestsIt() {
        let updates = AppUpdates { true }
        var installed = false
        updates.showReady { installed = $0 == .install }
        XCTAssertFalse(installed)
        XCTAssertFalse(updates.running)
        XCTAssertFalse(updates.failure.isEmpty)
    }
    @MainActor func testUnfinishedOperationBlocksUpdateBeforeAnyNetworkOrInstall() {
        let updates = AppUpdates { false }
        updates.install()
        XCTAssertFalse(updates.running)
        XCTAssertTrue(updates.failure.contains("保存草稿"))
        var choice: SPUUserUpdateChoice?
        updates.showReady { choice = $0 }
        XCTAssertEqual(choice, .dismiss)
    }
    @MainActor func testUnknownDownloadLengthProgressClampingAndCancelLifecycle() {
        let updates = AppUpdates { true }
        var cancelled = false
        updates.showDownloadInitiated { cancelled = true }
        updates.showDownloadDidReceiveData(ofLength: 10)
        XCTAssertNil(updates.progress)
        updates.showDownloadDidReceiveExpectedContentLength(100)
        updates.showDownloadDidReceiveData(ofLength: 190)
        XCTAssertEqual(updates.progress, 1)
        updates.cancel()
        XCTAssertTrue(cancelled)
        updates.showDownloadInitiated { XCTFail("Must not cancel during extraction") }
        updates.showDownloadDidStartExtractingUpdate()
        XCTAssertFalse(updates.canCancel)
        updates.cancel()
        updates.dismissUpdateInstallation()
        XCTAssertFalse(updates.running)
        XCTAssertNil(updates.progress)
    }
}
