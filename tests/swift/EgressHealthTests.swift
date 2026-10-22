import XCTest
@testable import SubscriptionStudio

final class EgressHealthTests: XCTestCase {
    func testRingColorRules() {
        XCTAssertNil(EgressHealth.evaluate(running: true, checked: true, exits: 1, allUS: true, failures: 0, markedChanged: false))
        XCTAssertNil(EgressHealth.evaluate(running: false, checked: false, exits: 0, allUS: true, failures: 0, markedChanged: false))
        XCTAssertEqual(EgressHealth.evaluate(running: false, checked: true, exits: 1, allUS: true, failures: 0, markedChanged: false), .ok)
        XCTAssertEqual(EgressHealth.evaluate(running: false, checked: true, exits: 1, allUS: true, failures: 2, markedChanged: false), .warning)
        XCTAssertEqual(EgressHealth.evaluate(running: false, checked: true, exits: 2, allUS: true, failures: 0, markedChanged: false), .warning)
        XCTAssertEqual(EgressHealth.evaluate(running: false, checked: true, exits: 1, allUS: true, failures: 0, markedChanged: true), .warning)
        XCTAssertEqual(EgressHealth.evaluate(running: false, checked: true, exits: 1, allUS: false, failures: 0, markedChanged: false), .failed)
        XCTAssertEqual(EgressHealth.evaluate(running: false, checked: true, exits: 0, allUS: true, failures: 5, markedChanged: false), .failed)
    }
}
