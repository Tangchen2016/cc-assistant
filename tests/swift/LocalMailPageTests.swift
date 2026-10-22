import XCTest
@testable import SubscriptionStudio

final class LocalMailPageTests: XCTestCase {
    @MainActor func testLoopbackMailPageIsScopedAndStopsWithModel() async throws {
        let model = MailAssistantModel(settings: .init())
        let url = try await model.localPage.open(model: model, email: "sky@example.com")
        defer { model.stop() }
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertTrue(LocalMailPage.permits(url.absoluteString))
        XCTAssertFalse(LocalMailPage.permits("http://127.0.0.1:9999/mail/anything"))
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (html, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer")
        XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("继续登录 Claude"))
        let (data, _) = try await session.data(from: url.appendingPathComponent("state"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["email"] as? String, "sky@example.com")
        XCTAssertNil(body["token"]); XCTAssertNil(body["settings"])
        var blocked = URLRequest(url: url.appendingPathComponent("state")); blocked.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        let (_, blockedResponse) = try await session.data(for: blocked)
        XCTAssertEqual((blockedResponse as? HTTPURLResponse)?.statusCode, 403)
        let (_, missingResponse) = try await session.data(from: url.deletingLastPathComponent().appendingPathComponent("wrong/state"))
        XCTAssertEqual((missingResponse as? HTTPURLResponse)?.statusCode, 404)
        model.stop(); XCTAssertFalse(LocalMailPage.permits(url.absoluteString))
    }
    @MainActor func testReplacingPageInvalidatesPreviousAccess() async throws {
        let model = MailAssistantModel(settings: .init())
        defer { model.stop() }
        let first = try await model.localPage.open(model: model, email: "first@example.com")
        let second = try await model.localPage.open(model: model, email: "second@example.com")
        XCTAssertNotEqual(first, second); XCTAssertFalse(LocalMailPage.permits(first.absoluteString)); XCTAssertTrue(LocalMailPage.permits(second.absoluteString))
    }
}
