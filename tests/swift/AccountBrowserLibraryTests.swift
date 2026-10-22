import XCTest
@testable import SubscriptionStudio

final class AccountBrowserLibraryTests: XCTestCase {
    @MainActor func testOverridesInheritPerFieldAndIsolateProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = RegistrationModel(directory: root.appendingPathComponent("default"))
        defaults.settings.proxy = "http://127.0.0.1:7890"; defaults.settings.timeZone = "Asia/Shanghai"
        let library = AccountBrowserLibrary(defaults: defaults, directory: root.appendingPathComponent("accounts"))
        let first = try library.model(for: "first@example.com")
        let second = try library.model(for: "second@example.com")
        XCTAssertNotEqual(first.browserProfile, second.browserProfile)
        XCTAssertNotEqual(first.browserProfile, defaults.browserProfile)
        let profile = first.settings.browserID
        var settings = try XCTUnwrap(library.entries["first@example.com"])
        settings.proxy = "http://127.0.0.1:9000"; settings.timeZone = "America/Los_Angeles"
        try library.save(settings, email: "first@example.com")
        XCTAssertEqual(try library.model(for: "first@example.com").settings.proxy, "http://127.0.0.1:9000")
        XCTAssertEqual(first.settings.timeZone, "America/Los_Angeles")
        XCTAssertEqual(second.settings.timeZone, "Asia/Shanghai")
        defaults.settings.proxy = "http://127.0.0.1:8888"; defaults.settings.timeZone = "Asia/Tokyo"
        XCTAssertEqual(try library.model(for: "second@example.com").settings.proxy, "http://127.0.0.1:8888")
        XCTAssertEqual(second.settings.timeZone, "Asia/Tokyo")
        XCTAssertEqual(try library.model(for: "first@example.com").settings.proxy, "http://127.0.0.1:9000")
        settings.proxy = nil; settings.timeZone = nil; try library.save(settings, email: "first@example.com")
        XCTAssertEqual(try library.model(for: "first@example.com").settings.proxy, "http://127.0.0.1:8888")
        XCTAssertEqual(first.settings.browserID, profile)
        settings.useSystemTimeZone = true; try library.save(settings, email: "first@example.com")
        XCTAssertNil(try library.model(for: "first@example.com").settings.timeZone)
        let reloaded = AccountBrowserLibrary(defaults: defaults, directory: root.appendingPathComponent("accounts"))
        XCTAssertEqual(try reloaded.model(for: "first@example.com").settings.browserID, profile)
        XCTAssertThrowsError(try reloaded.model(for: "first@example.com", preferredProfileID: UUID()))
    }
    @MainActor func testLegacyAssociationAndInvalidConfigProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = RegistrationModel(directory: root.appendingPathComponent("default"))
        let directory = root.appendingPathComponent("accounts")
        let library = AccountBrowserLibrary(defaults: defaults, directory: directory)
        XCTAssertTrue(try library.model(for: "legacy@example.com", preferredProfileID: defaults.settings.browserID) === defaults)
        var value = AccountBrowserOverride(); value.proxy = "not-a-proxy"
        XCTAssertThrowsError(try library.save(value, email: "first@example.com"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("environments.json")
        let invalid = Data("broken json".utf8); try invalid.write(to: file)
        let broken = AccountBrowserLibrary(defaults: defaults, directory: directory)
        XCTAssertThrowsError(try broken.model(for: "first@example.com"))
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }
}
