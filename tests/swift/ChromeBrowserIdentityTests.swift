import XCTest
@testable import SubscriptionStudio

final class ChromeBrowserIdentityTests: XCTestCase {
    @MainActor func testFinderIconPreservesVendorSignatureFilesAndBrowserTimeZone() throws {
        guard let source = ManagedChrome.executable else { throw XCTSkip("未安装 Chrome") }
        let icon = URL(fileURLWithPath: "/Applications/cc助手.app/Contents/Resources/AppIcon.icns")
        guard FileManager.default.fileExists(atPath: icon.path) else { throw XCTSkip("未安装 cc助手图标资源") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cc-signed-icon-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("registration/chrome-profiles/fixture")
        let original = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let originalSignature = try ChromeBrowserIdentity.signature(bundle: original)
        let importantFiles = ["Contents/Info.plist", "Contents/MacOS/\(source.lastPathComponent)", "Contents/_CodeSignature/CodeResources"]
        let before = try importantFiles.map { try Data(contentsOf: original.appendingPathComponent($0)) }
        let executable = try ChromeBrowserIdentity.prepare(source: source, profile: profile, icon: icon)
        let bundle = ChromeBrowserIdentity.bundle(profile: profile)
        XCTAssertNotEqual(executable, source)
        XCTAssertEqual(try ChromeBrowserIdentity.signature(bundle: bundle), originalSignature)
        for (index, path) in importantFiles.enumerated() {
            XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(path)), before[index])
            XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent(path)), before[index])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Icon\r").path))
        XCTAssertEqual(try ChromeBrowserIdentity.prepare(source: source, profile: profile, icon: icon), executable)
        let unsigned = root.appendingPathComponent("unsigned.app/Contents/MacOS/unsigned")
        try FileManager.default.createDirectory(at: unsigned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a signed executable".utf8).write(to: unsigned)
        XCTAssertThrowsError(try ChromeBrowserIdentity.prepare(source: unsigned, profile: profile, icon: icon))
    }
}

final class ChromeProfileLabelTests: XCTestCase {
    func testLabelMergesIntoExistingPrefsAndKeepsOtherKeys() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try Data(#"{"browser":{"x":1},"profile":{"info_cache":{"Default":{"avatar_icon":"a"}}}}"#.utf8).write(to: profile.appendingPathComponent("Local State"))
        ChromeProfileLabel.write("cc · a@example.invalid", profile: profile)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: profile.appendingPathComponent("Local State"))) as? [String: Any])
        let entry = try XCTUnwrap(((state["profile"] as? [String: Any])?["info_cache"] as? [String: Any])?["Default"] as? [String: Any])
        XCTAssertEqual(entry["name"] as? String, "cc · a@example.invalid")
        XCTAssertEqual(entry["avatar_icon"] as? String, "a")
        XCTAssertNotNil(state["browser"])
        let prefs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: profile.appendingPathComponent("Default/Preferences"))) as? [String: Any])
        XCTAssertEqual((prefs["profile"] as? [String: Any])?["name"] as? String, "cc · a@example.invalid")
        XCTAssertNotNil(((prefs["browser"] as? [String: Any])?["theme"] as? [String: Any])?["user_color"])
        // Account bookmark: pinned first, user bookmarks kept, re-pinning does not duplicate.
        try Data(#"{"checksum":"old","roots":{"bookmark_bar":{"id":"1","type":"folder","name":"bar","children":[{"id":"9","type":"url","name":"mine","url":"https://example.com/"}]}},"version":1}"#.utf8).write(to: profile.appendingPathComponent("Default/Bookmarks"))
        ChromeProfileLabel.write("cc · a@example.invalid", profile: profile, account: "a@example.invalid")
        ChromeProfileLabel.write("cc · a@example.invalid", profile: profile, account: "a@example.invalid")
        let marks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: profile.appendingPathComponent("Default/Bookmarks"))) as? [String: Any])
        let bar = try XCTUnwrap(((marks["roots"] as? [String: Any])?["bookmark_bar"] as? [String: Any])?["children"] as? [[String: Any]])
        XCTAssertEqual(bar.map { $0["name"] as? String }, ["👤 a@example.invalid", "mine"])
        XCTAssertNil(marks["checksum"])
        XCTAssertNotEqual(ChromeProfileLabel.themeColor("cc · a@example.invalid"), ChromeProfileLabel.themeColor("cc · b@example.invalid"))
        // Unreadable files are left untouched.
        try Data("not json".utf8).write(to: profile.appendingPathComponent("Local State"))
        ChromeProfileLabel.write("x", profile: profile)
        XCTAssertEqual(try String(contentsOf: profile.appendingPathComponent("Local State")), "not json")
    }
}
