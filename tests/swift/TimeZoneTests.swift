import XCTest
@testable import SubscriptionStudio

final class TimeZoneTests: XCTestCase {
    func testOffsetsHandleFractionalHoursAndNegativeSign() {
        XCTAssertEqual(TimeZoneObservation(identifier: "Asia/Kathmandu", utcOffsetMinutes: 345).offsetText, "UTC+05:45")
        XCTAssertEqual(TimeZoneObservation(identifier: "America/St_Johns", utcOffsetMinutes: -210).offsetText, "UTC−03:30")
        XCTAssertEqual(TimeZoneObservation(identifier: "UTC", utcOffsetMinutes: 0).offsetText, "UTC+00:00")
    }
    func testSystemOffsetUsesMeasurementDateIncludingDST() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let format = ISO8601DateFormatter()
        let winter = try XCTUnwrap(format.date(from: "2026-01-15T12:00:00Z"))
        let summer = try XCTUnwrap(format.date(from: "2026-07-15T12:00:00Z"))
        XCTAssertEqual(TimeZoneDiagnostics.system(at: winter, zone: zone).utcOffsetMinutes, -300)
        XCTAssertEqual(TimeZoneDiagnostics.system(at: summer, zone: zone).utcOffsetMinutes, -240)
    }
    func testBrowserPayloadValidation() throws {
        let value = try XCTUnwrap(TimeZoneDiagnostics.parse("{\"identifier\":\"Asia/Kathmandu\",\"utcOffsetMinutes\":345}"))
        XCTAssertEqual(value.offsetText, "UTC+05:45")
        for text in ["{\"identifier\":\"UTC\",\"utcOffsetMinutes\":true}", "{\"identifier\":\"UTC\",\"utcOffsetMinutes\":9999}", "{\"identifier\":\"UTC\",\"utcOffsetMinutes\":1.5}", "{\"identifier\":\"<script>\",\"utcOffsetMinutes\":0}"] { XCTAssertNil(TimeZoneDiagnostics.parse(text)) }
    }
}
