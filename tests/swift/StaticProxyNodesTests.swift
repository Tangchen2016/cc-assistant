import XCTest
@testable import SubscriptionStudio

final class StaticProxyNodesTests: XCTestCase {
    private let link = "vless://11111111-2222-4333-8444-555555555555@node.example.com:443?security=tls&type=ws&path=%2Fsocket#Original"
    private func profile(mobile: Bool = false) -> SubscriptionProfile {
        var value: SubscriptionProfile = mobile ? .mobile : .empty
        value.name = mobile ? "Phone" : "Clash"; value.sourceUrl = mobile ? "" : "https://example.com/sub"
        value.groups[0].fixedExit = link; return value
    }
    @MainActor func testMigrationDeduplicatesEquivalentExitsAndKeepsIdentitiesDraftAndBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clash = SubscriptionRecord(id: String(repeating: "a", count: 32), manageKey: String(repeating: "b", count: 64), downloadKey: String(repeating: "c", count: 64), profile: profile(), updatedAt: 123)
        var phoneProfile = profile(mobile: true); phoneProfile.groups[0].fixedExit = link.replacingOccurrences(of: "#Original", with: "#Phone")
        let phone = SubscriptionRecord(id: String(repeating: "d", count: 32), manageKey: String(repeating: "e", count: 64), downloadKey: String(repeating: "f", count: 64), profile: phoneProfile, updatedAt: 456)
        var state = SubscriptionState(); state.records = [clash, phone]; state.draft = clash.profile; state.currentId = clash.id
        let bytes = try JSONEncoder().encode(state)
        try SubscriptionStorage.privateWrite(bytes, to: root.appendingPathComponent("profiles.json"))
        let store = SubscriptionStorage(directory: root)
        XCTAssertNil(store.error); XCTAssertEqual(store.staticNodes.count, 1)
        let id = try XCTUnwrap(store.staticNodes.first?.id)
        XCTAssertEqual(store.state.records.map { $0.profile.groups[0].staticNodeId }, [id, id])
        XCTAssertEqual(store.state.draft?.groups[0].staticNodeId, id)
        XCTAssertEqual(store.state.currentId, clash.id)
        XCTAssertEqual(store.state.records.map(\.id), [clash.id, phone.id])
        XCTAssertEqual(store.state.records.map(\.downloadKey), [clash.downloadKey, phone.downloadKey])
        XCTAssertEqual(store.state.records.map(\.manageKey), [clash.manageKey, phone.manageKey])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profiles.before-static-nodes.json")), bytes)
        let again = SubscriptionStorage(directory: root)
        XCTAssertEqual(again.staticNodes.first?.id, id)
        XCTAssertEqual(again.state.records, store.state.records)
    }
    @MainActor func testEditingOneNodeUpdatesBothClientsAndDraftWithoutChangingRemoteLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SubscriptionStorage(directory: root)
        let clash = try store.save(profile(), id: nil); let phone = try store.save(profile(mobile: true), id: nil)
        let id = try XCTUnwrap(store.staticNodes.first?.id)
        let remote = SubscriptionRemote(id: String(repeating: "a", count: 32), manageKey: String(repeating: "b", count: 64), downloadKey: String(repeating: "c", count: 64), subscriptionUrl: "https://node.tangchen02.top/remote-sub/fixture", updatedAt: 10)
        try store.remote(clash.id, value: remote); try store.remote(phone.id, value: remote)
        var draft = clash.profile; draft.name = "Unsaved draft"; try store.saveDraft(draft, currentId: clash.id)
        let nextURL = link.replacingOccurrences(of: "node.example.com", with: "updated.example.com")
        try store.saveStaticNode(id: id, name: "Shared exit", url: nextURL)
        XCTAssertEqual(store.staticNodes.count, 1)
        XCTAssertTrue(store.state.records.allSatisfy { $0.profile.groups[0].fixedExit == nextURL && $0.profile.groups[0].staticNodeId == id })
        XCTAssertTrue(store.state.records.allSatisfy { $0.remote?.subscriptionUrl == remote.subscriptionUrl && $0.remote?.manageKey == remote.manageKey && $0.remote?.lastError != nil })
        XCTAssertEqual(store.state.records.first(where: { $0.id == clash.id })?.downloadKey, clash.downloadKey)
        XCTAssertEqual(store.state.records.first(where: { $0.id == phone.id })?.downloadKey, phone.downloadKey)
        XCTAssertEqual(store.state.draft?.name, "Unsaved draft")
        XCTAssertEqual(store.state.draft?.groups[0].fixedExit, nextURL)
        XCTAssertEqual(try store.resolved(clash.profile).groups[0].fixedExit, nextURL)
        let yaml = try SubscriptionCore.transform(["proxies": [["name": "HK", "type": "ss"]]], profile: store.resolved(clash.profile))
        let parsed = try SubscriptionCore.parse(yaml)
        XCTAssertEqual((parsed["proxies"] as? [[String: Any]])?.last?["server"] as? String, "updated.example.com")
        XCTAssertEqual(SubscriptionStorage(directory: root).staticNodes.first?.url, nextURL)
    }
    @MainActor func testMissingReferenceCannotFallBackToOldCredentialSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SubscriptionStorage(directory: root)
        try store.saveStaticNode(id: nil, name: "Saved", url: link)
        let bytes = try Data(contentsOf: root.appendingPathComponent("profiles.json"))
        var broken = profile(); broken.groups[0].staticNodeId = String(repeating: "a", count: 32)
        XCTAssertThrowsError(try store.resolved(broken))
        XCTAssertThrowsError(try store.save(broken, id: nil))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profiles.json")), bytes)
    }
    @MainActor func testUsedNodeCannotBeDeletedAndInvalidEditsAreAtomic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SubscriptionStorage(directory: root)
        let record = try store.save(profile(), id: nil)
        let node = try XCTUnwrap(store.staticNodes.first)
        XCTAssertThrowsError(try store.removeStaticNode(node.id))
        let bytes = try Data(contentsOf: root.appendingPathComponent("profiles.json"))
        XCTAssertThrowsError(try store.saveStaticNode(id: node.id, name: "Broken", url: link.replacingOccurrences(of: "security=tls", with: "security=none")))
        XCTAssertThrowsError(try store.saveStaticNode(id: nil, name: "Duplicate", url: link + "Remark"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profiles.json")), bytes)
        try store.remove(record.id)
        var draft = profile(); draft.groups[0].staticNodeId = node.id; try store.saveDraft(draft, currentId: nil)
        XCTAssertThrowsError(try store.removeStaticNode(node.id))
        try store.saveDraft(nil, currentId: nil); try store.removeStaticNode(node.id)
        XCTAssertTrue(store.staticNodes.isEmpty)
    }
}
