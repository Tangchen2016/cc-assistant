import XCTest
@testable import SubscriptionStudio

final class BrowserProcessIdentityTests: XCTestCase {
    private func bytes(executable: String, arguments: [String], environment: [String]) -> [UInt8] {
        var count = Int32(arguments.count)
        return withUnsafeBytes(of: &count) { Array($0) } + Array(executable.utf8) + [0, 0, 0] + arguments.flatMap { Array($0.utf8) + [0] } + environment.flatMap { Array($0.utf8) + [0] } + [0]
    }
    func testOnlyExactExecutableAndPrivateProfileCanBeAdopted() throws {
        let source = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        let profile = URL(fileURLWithPath: "/private/cc-profile")
        let arguments = [source.path, "--user-data-dir=\(profile.path)", "--proxy-server=http://127.0.0.1:7890"]
        let raw = bytes(executable: source.path, arguments: arguments, environment: ["UNRELATED_SECRET=not-exported", "TZ=America/Los_Angeles", "PATH=/usr/bin"])
        let result = try XCTUnwrap(BrowserProcessIdentity.parse(raw, pid: 1234, profile: profile, allowedExecutables: [source]))
        XCTAssertEqual(result.pid, 1234)
        XCTAssertEqual(result.proxy, "http://127.0.0.1:7890")
        XCTAssertEqual(result.timeZone, "America/Los_Angeles")
        XCTAssertFalse(result.arguments.contains { $0.contains("UNRELATED_SECRET") })
        XCTAssertNil(BrowserProcessIdentity.parse(raw, pid: 1234, profile: profile.appendingPathComponent("other"), allowedExecutables: [source]))
        XCTAssertNil(BrowserProcessIdentity.parse(raw, pid: 1234, profile: profile, allowedExecutables: [URL(fileURLWithPath: "/bin/sleep")]))
        XCTAssertNil(BrowserProcessIdentity.parse([0, 0, 0, 0], pid: 1234, profile: profile, allowedExecutables: [source]))
        XCTAssertNil(BrowserProcessIdentity.parse(Array(raw.prefix(20)), pid: 1234, profile: profile, allowedExecutables: [source]))
    }
    @MainActor func testTrackedSessionStateRestartAndClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("browser")
        try Data("#!/bin/sh\nexec /bin/sleep 15\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let manager = ManagedChrome(), profile = directory.appendingPathComponent("profile")
        var config = PureBrowserConfiguration(executable: executable, name: "Test", proxy: "http://127.0.0.1:7890")
        XCTAssertEqual(manager.runtime(profile: profile, configuration: config).phase, .stopped)
        try manager.open(configuration: config, profile: profile, page: "about:blank")
        XCTAssertEqual(manager.runtime(profile: profile, configuration: config).phase, .starting)
        config.timeZone = "Asia/Tokyo"
        XCTAssertEqual(manager.runtime(profile: profile, configuration: config).phase, .restartRequired)
        XCTAssertTrue(manager.close(profile: profile))
        for _ in 0..<100 {
            if manager.runtime(profile: profile, configuration: config).phase == .stopped { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(manager.runtime(profile: profile, configuration: config).phase, .stopped)
        XCTAssertFalse(manager.close(profile: profile))
    }
}


extension BrowserProcessIdentityTests {
    func testLaunchRecordCannotAttachToAnotherProcessOrSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = BrowserLaunchRecord(pid: 1234, sessionID: "session-one", proxy: "http://127.0.0.1:7890", timeZone: "America/Los_Angeles")
        try JSONEncoder().encode(record).write(to: BrowserLaunchRecord.file(profile: directory))
        let matching = BrowserProcessIdentity(pid: 1234, executable: "/chrome", arguments: ["--cc-assistant-session-id=session-one"], timeZone: nil)
        XCTAssertEqual(BrowserLaunchRecord.read(profile: directory, identity: matching)?.timeZone, "America/Los_Angeles")
        let anotherPID = BrowserProcessIdentity(pid: 1235, executable: "/chrome", arguments: matching.arguments, timeZone: nil)
        XCTAssertNil(BrowserLaunchRecord.read(profile: directory, identity: anotherPID))
        let anotherSession = BrowserProcessIdentity(pid: 1234, executable: "/chrome", arguments: ["--cc-assistant-session-id=session-two"], timeZone: nil)
        XCTAssertNil(BrowserLaunchRecord.read(profile: directory, identity: anotherSession))
        try Data("broken".utf8).write(to: BrowserLaunchRecord.file(profile: directory))
        XCTAssertNil(BrowserLaunchRecord.read(profile: directory, identity: matching))
    }
}
