import XCTest
@testable import SubscriptionStudio

final class BrowserTimeZoneSettingsTests: XCTestCase {
    @MainActor func testOldSettingsLoadAndTimeZonePersistsWithoutChangingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var original = RegistrationSettings()
        original.domain = "example.com"
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "timeZone")
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("settings.json"))
        let model = RegistrationModel(directory: directory)
        XCTAssertNil(model.settings.timeZone)
        XCTAssertEqual(model.settings.browserID, original.browserID)
        model.settings.timeZone = "America/Los_Angeles"
        XCTAssertTrue(model.save())
        let loaded = RegistrationModel(directory: directory)
        XCTAssertEqual(loaded.settings.timeZone, "America/Los_Angeles")
        XCTAssertEqual(loaded.settings.browserID, original.browserID)
        XCTAssertEqual(loaded.settings.domain, original.domain)
        XCTAssertEqual(loaded.settings.proxy, original.proxy)
        let before = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        loaded.settings.timeZone = "Invalid/Zone"
        XCTAssertFalse(loaded.save())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("settings.json")), before)
        loaded.settings.timeZone = nil
        XCTAssertTrue(loaded.save())
        XCTAssertNil(RegistrationModel(directory: directory).settings.timeZone)
    }
    @MainActor func testBrowserLaunchUsesAllowlistedAutoDetectionPage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = RegistrationModel(directory: directory)
        model.settings.timeZone = "America/Los_Angeles"
        let arguments = try model.arguments(for: RegistrationModel.browserCheckPage)
        XCTAssertEqual(arguments.last, "https://tangchen02.top/apps/cc-assistant/check/?autostart=1")
        XCTAssertTrue(arguments.contains("--user-data-dir=\(model.browserProfile.path)"))
        XCTAssertTrue(arguments.contains("--proxy-server=\(model.settings.proxy)"))
        XCTAssertThrowsError(try model.arguments(for: "https://example.com/?autostart=1"))
        XCTAssertThrowsError(try model.arguments(for: RegistrationModel.browserCheckPage + "&redirect=https://example.com"))
    }
    @MainActor func testValidationAndEnvironmentAreScopedToChildProcess() throws {
        XCTAssertEqual(try RegistrationModel.validatedTimeZone(" America/Los_Angeles "), "America/Los_Angeles")
        XCTAssertNil(try RegistrationModel.validatedTimeZone(" "))
        XCTAssertThrowsError(try RegistrationModel.validatedTimeZone("TZ=Bad"))
        let base = ["TZ": "Asia/Shanghai", "PATH": "/usr/bin"]
        let configuration = PureBrowserConfiguration(executable: URL(fileURLWithPath: "/missing"), name: "Chrome", proxy: "http://127.0.0.1:7890", timeZone: "America/New_York")
        XCTAssertEqual(configuration.environment(base: base), ["TZ": "America/New_York", "PATH": "/usr/bin"])
        var system = configuration; system.timeZone = nil
        XCTAssertNil(system.environment(base: base)["TZ"])
        XCTAssertEqual(base["TZ"], "Asia/Shanghai")
    }
    @MainActor func testManagedSessionRejectsTimeZoneChangeUntilClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("browser")
        try Data("#!/bin/sh\nprintf '%s' \"$TZ\" > \"$(dirname \"$0\")/observed-tz\"\nexec /bin/sleep 15\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let manager = ManagedChrome()
        let profile = directory.appendingPathComponent("profile")
        var configuration = PureBrowserConfiguration(executable: executable, name: "Test", proxy: "http://127.0.0.1:7890", timeZone: "Asia/Tokyo")
        try manager.open(configuration: configuration, profile: profile, page: "about:blank")
        defer { _ = manager.close(profile: profile) }
        let observation = directory.appendingPathComponent("observed-tz")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: observation.path) { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(try String(contentsOf: observation), "Asia/Tokyo")
        configuration.timeZone = "America/New_York"
        XCTAssertThrowsError(try manager.open(configuration: configuration, profile: profile, page: "about:blank"))
        XCTAssertTrue(manager.close(profile: profile))
    }
}
