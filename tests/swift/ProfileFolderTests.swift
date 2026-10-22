import XCTest
@testable import SubscriptionStudio

final class ProfileFolderTests: XCTestCase {
    @MainActor func testListsOldFoldersAndSwitchesBackKeepingLogin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RegistrationModel(directory: root)
        let first = model.settings.browserID
        let profiles = root.appendingPathComponent("chrome-profiles")
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent("\(first.uuidString)/Default"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: profiles.appendingPathComponent("\(first.uuidString)/Default/Cookies").path, contents: Data("x".utf8))
        model.newBrowserEnvironment()
        let second = model.settings.browserID
        XCTAssertNotEqual(first, second)
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent(second.uuidString), withIntermediateDirectories: true)

        let folders = RegistrationModel.profileFolders(in: root)
        XCTAssertEqual(Set(folders.map(\.id)), [first, second])  // the old folder is still listed
        XCTAssertEqual(folders.first { $0.id == first }?.hasLogin, true)

        model.useProfile(first)
        XCTAssertEqual(model.settings.browserID, first)
        model.useProfile(UUID())  // unknown folder is refused
        XCTAssertEqual(model.settings.browserID, first)
    }
}
