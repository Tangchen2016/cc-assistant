import XCTest
@testable import SubscriptionStudio

final class BrowserExitTimeZoneTests: XCTestCase {
    private func payload(ip: String = "203.0.113.10", zone: String = "America/Los_Angeles", success: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["success": success, "ip": ip, "country": "United States", "region": "California", "city": "Los Angeles", "timezone": ["id": zone]])
    }
    func testValidMatchedIPAndActualTimeZone() throws {
        let value = try BrowserExitTimeZoneLookup.parse(payload(), expectedIP: "203.0.113.10")
        XCTAssertEqual(value.ip, "203.0.113.10")
        XCTAssertEqual(value.identifier, "America/Los_Angeles")
        XCTAssertEqual(value.location, "United States · California · Los Angeles")
        XCTAssertTrue(value.display.contains("UTC"))
        let ipv6 = try BrowserExitTimeZoneLookup.parse(payload(ip: "2001:db8:0:0::1", zone: "Asia/Tokyo"), expectedIP: "2001:db8::1")
        XCTAssertEqual(ipv6.ip, "2001:db8::1")
    }
    func testRejectsMismatchFailureMissingZoneAndOversizedResponse() throws {
        XCTAssertThrowsError(try BrowserExitTimeZoneLookup.parse(payload(), expectedIP: "203.0.113.11"))
        XCTAssertThrowsError(try BrowserExitTimeZoneLookup.parse(payload(zone: "Not/AZone"), expectedIP: "203.0.113.10"))
        XCTAssertThrowsError(try BrowserExitTimeZoneLookup.parse(payload(success: false), expectedIP: "203.0.113.10"))
        for data in [Data("{\"success\":true,\"ip\":\"203.0.113.10\",\"country\":\"US\"}".utf8), Data("{\"success\":1}".utf8), Data(repeating: 32, count: 32769)] {
            XCTAssertThrowsError(try BrowserExitTimeZoneLookup.parse(data, expectedIP: "203.0.113.10"))
        }
    }
    @MainActor func testRecommendationDoesNotSelectAndProxyChangeInvalidatesCache() async throws {
        guard ManagedChrome.executable != nil else { throw XCTSkip("本机没有 Chrome") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = RegistrationModel(directory: directory)
        let value = BrowserExitTimeZone(ip: "203.0.113.10", identifier: "America/Los_Angeles", location: "California")
        await model.refreshExitTimeZone(resolve: { _ in value })
        XCTAssertEqual(model.exitTimeZone, value)
        XCTAssertNil(model.settings.timeZone)
        await model.refreshExitTimeZone(resolve: { _ in XCTFail("短时缓存不应重复查询"); return value })
        model.settings.timeZone = "Asia/Tokyo"
        XCTAssertEqual(model.exitTimeZone, value)
        model.settings.proxy = "http://127.0.0.1:7891"
        XCTAssertNil(model.exitTimeZone)
        XCTAssertFalse(model.checkingExitTimeZone)
        await model.refreshExitTimeZone(resolve: { configuration in
            XCTAssertEqual(configuration.proxy, "http://127.0.0.1:7891")
            return value
        })
        XCTAssertEqual(model.settings.timeZone, "Asia/Tokyo")
        model.settings.browserID = UUID()
        XCTAssertNil(model.exitTimeZone)
    }
    @MainActor func testStaleResponseCannotReappearAfterConfigurationChange() async throws {
        guard ManagedChrome.executable != nil else { throw XCTSkip("本机没有 Chrome") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = RegistrationModel(directory: directory)
        let started = expectation(description: "Resolver started")
        let task = Task {
            await model.refreshExitTimeZone(resolve: { _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 100_000_000)
                return .init(ip: "203.0.113.10", identifier: "America/Los_Angeles", location: "California")
            })
        }
        await fulfillment(of: [started], timeout: 2)
        model.settings.proxy = "http://127.0.0.1:7892"
        await task.value
        XCTAssertNil(model.exitTimeZone)
        XCTAssertTrue(model.exitTimeZoneMessage.contains("已改变"))
        XCTAssertFalse(model.checkingExitTimeZone)
        await model.refreshExitTimeZone(resolve: { _ in throw SubscriptionFailure("查询失败") })
        XCTAssertNil(model.exitTimeZone)
        XCTAssertEqual(model.exitTimeZoneMessage, "查询失败")
    }
}
