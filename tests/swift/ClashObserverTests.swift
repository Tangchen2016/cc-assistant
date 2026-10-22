import XCTest
@testable import SubscriptionStudio

final class ClashObserverTests: XCTestCase {
    func testSplitsRealClashPartyArgumentsWithSpaces() {
        // As printed by `ps` for Clash Party's root-owned core.
        let args = ClashObserver.splitFlags("/Applications/Clash Party.app/Contents/Resources/sidecar/mihomo -d /Users/u/Library/Application Support/mihomo-party/work -ext-ctl-unix /tmp/mihomo-party-501-85789.sock")
        XCTAssertEqual(args, ["/Applications/Clash Party.app/Contents/Resources/sidecar/mihomo", "-d", "/Users/u/Library/Application Support/mihomo-party/work", "-ext-ctl-unix", "/tmp/mihomo-party-501-85789.sock"])
    }

    func testWatchedDomainMatching() {
        let domains = ClashObserver.claudeDomains
        XCTAssertTrue(ClashObserver.matches("claude.ai:443", domains))
        XCTAssertTrue(ClashObserver.matches("api.anthropic.com:443", domains))
        XCTAssertFalse(ClashObserver.matches("notclaude.ai:443", domains))
        XCTAssertFalse(ClashObserver.matches("ws.chatgpt.com:443", domains))
    }
}
