import XCTest
@testable import SubscriptionStudio

final class SubscriptionAddressModeTests: XCTestCase {
    private var profile: SubscriptionProfile {
        var value = SubscriptionProfile.empty
        value.sourceUrl = "https://example.com/sub"
        value.groups[0].nodes = ["Synthetic"]
        return value
    }
    private var remote: SubscriptionRemote {
        .init(id: String(repeating: "a", count: 32), manageKey: String(repeating: "b", count: 64), downloadKey: String(repeating: "c", count: 64), subscriptionUrl: "https://node.tangchen02.top/remote-sub/synthetic/config.yaml", updatedAt: 1)
    }
    @MainActor func testNewEditorDefaultsToRemoteAndResumesSelectedDraftMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SubscriptionModel(storage: SubscriptionStorage(directory: root))
        model.create()
        XCTAssertEqual(model.addressMode, .remote)
        XCTAssertEqual(model.storage.state.draftAddressMode, .remote)
        model.selectAddressMode(.local)
        let restored = SubscriptionModel(storage: SubscriptionStorage(directory: root))
        restored.resume()
        XCTAssertEqual(restored.addressMode, .local)
        restored.create()
        XCTAssertEqual(restored.addressMode, .remote)
    }
    @MainActor func testSwitchingAddressModeRetainsBothExistingLinksAndCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SubscriptionStorage(directory: root)
        let saved = try storage.save(profile, id: nil, addressMode: .remote)
        XCTAssertNil(saved.preferredURL, "An unpublished remote record must not silently return a local address")
        try storage.remote(saved.id, value: remote)
        let model = SubscriptionModel(storage: storage)
        model.showAddresses(try XCTUnwrap(storage.state.records.first))
        XCTAssertEqual(model.addressMode, .remote)
        XCTAssertEqual(model.current?.preferredURL, remote.subscriptionUrl)
        try storage.addressMode(saved.id, value: .local)
        let local = try XCTUnwrap(SubscriptionStorage(directory: root).state.records.first)
        XCTAssertEqual(local.preferredAddressMode, .local)
        XCTAssertEqual(local.preferredURL, saved.localURL)
        XCTAssertEqual(local.remote, remote)
        XCTAssertEqual(local.downloadKey, saved.downloadKey)
        XCTAssertEqual(local.manageKey, saved.manageKey)
        let edited = try storage.save(profile, id: saved.id, addressMode: .remote)
        XCTAssertEqual(edited.preferredURL, remote.subscriptionUrl)
        XCTAssertEqual(edited.localURL, saved.localURL)
        XCTAssertEqual(SubscriptionStorage(directory: root).state.draftAddressMode, .remote)
    }
    func testLegacyRecordsKeepTheirExistingAddressAndMobileRemainsRemote() throws {
        let oldJSON = """
        {"version":1,"records":[{"id":"legacy","manageKey":"manage","downloadKey":"download","profile":{"name":"Test","sourceUrl":"https://example.com/sub","groups":[],"rules":[]},"updatedAt":1}]}
        """
        var record = try XCTUnwrap(JSONDecoder().decode(SubscriptionState.self, from: Data(oldJSON.utf8)).records.first)
        XCTAssertNil(record.addressMode)
        XCTAssertEqual(record.preferredAddressMode, .local)
        XCTAssertEqual(record.preferredURL, record.localURL)
        record.remote = remote
        XCTAssertEqual(record.preferredAddressMode, .remote)
        XCTAssertEqual(record.preferredURL, remote.subscriptionUrl)
        record.profile = .mobile
        record.addressMode = .local
        XCTAssertEqual(record.preferredAddressMode, .remote)
    }
    @MainActor func testOutputCanSwitchToLocalWithoutPublishingOrReplacingRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SubscriptionStorage(directory: root)
        let saved = try storage.save(profile, id: nil, addressMode: .remote)
        let model = SubscriptionModel(storage: storage)
        model.showAddresses(saved)
        model.selectAddressMode(.local)
        for _ in 0..<100 where model.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.error.isEmpty)
        XCTAssertEqual(model.addressMode, .local)
        XCTAssertEqual(model.current?.id, saved.id)
        XCTAssertEqual(model.current?.preferredURL, saved.localURL)
        XCTAssertNil(model.current?.remote)
        XCTAssertEqual(storage.state.records.count, 1)
    }
    @MainActor func testAddressOnlyDraftChangeRemainsVisibleWithoutChangingSavedChoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SubscriptionStorage(directory: root)
        let saved = try storage.save(profile, id: nil, addressMode: .remote)
        let model = SubscriptionModel(storage: storage)
        model.showAddresses(saved)
        model.stage = "review"
        XCTAssertFalse(model.hasUnfinishedDraft)
        model.selectAddressMode(.local)
        model.list()
        XCTAssertTrue(model.hasUnfinishedDraft)
        XCTAssertEqual(model.current?.preferredAddressMode, .remote)
        let restored = SubscriptionModel(storage: SubscriptionStorage(directory: root))
        restored.resume()
        XCTAssertEqual(restored.addressMode, .local)
        XCTAssertEqual(restored.profile, saved.profile)
    }
}
