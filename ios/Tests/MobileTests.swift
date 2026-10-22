import XCTest
#if os(iOS)
@testable import CCAssistantIOS
#else
@testable import MobileDiagnostics
@testable import SubscriptionStudio
#endif

final class MobileTests: XCTestCase {
    func testTraceRequiresMatchingHostAndUniqueValidFields() throws {
        let value = try MobileTrace.parse("h=claude.ai\nip=203.0.113.7\nloc=US\n", host: "claude.ai")
        XCTAssertEqual(value.ip, "203.0.113.7")
        XCTAssertThrowsError(try MobileTrace.parse("h=claude.com\nip=203.0.113.7\nloc=US", host: "claude.ai"))
        XCTAssertThrowsError(try MobileTrace.parse("h=claude.ai\nip=203.0.113.7\nip=203.0.113.8\nloc=US", host: "claude.ai"))
        XCTAssertThrowsError(try MobileTrace.parse("h=claude.ai\nip=999.1.2.3\nloc=US", host: "claude.ai"))
        XCTAssertThrowsError(try MobileTrace.parse(String(repeating: " ", count: 8193), host: "claude.ai"))
        XCTAssertEqual(MobileTrace.normalizedIP("2001:0db8::1"), "2001:db8::1")
    }
    @MainActor func testSingleMarkerPersistsReplacesAndClears() throws {
        let name = "cc-ios-tests-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MobileEgressModel(defaults: defaults)
        model.mark("203.0.113.1"); model.mark("203.0.113.2")
        XCTAssertEqual(MobileEgressModel(defaults: defaults).marker, "203.0.113.2")
        model.mark("not an ip"); XCTAssertEqual(model.marker, "203.0.113.2")
        model.mark(nil); XCTAssertNil(MobileEgressModel(defaults: defaults).marker)
    }
    @MainActor func testAccountsRoundTripAndMergeConflictPreservesFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountPoolStore(fileURL: directory.appendingPathComponent("accounts.json"))
        let draft = AccountPoolDraft(email: " Example@example.com ", status: .inUse, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let row = try store.save(draft, now: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try store.backupData(); XCTAssertEqual(try store.importData(data), 0)
        try store.delete(row.id); try store.restore(row.id)
        let before = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.importData(data))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(AccountPoolStore(fileURL: store.fileURL).records.first?.email, "example@example.com")
    }
}
