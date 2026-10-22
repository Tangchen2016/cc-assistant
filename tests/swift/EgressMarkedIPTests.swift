import XCTest
@testable import SubscriptionStudio

final class EgressMarkedIPTests: XCTestCase {
    @MainActor func testSingleMarkerReplacesPersistsAndClears() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("marked-ip.json")
        let store = EgressMarkedIPStore(fileURL: file)
        try store.mark("203.0.113.1"); try store.mark("203.0.113.2")
        let loaded = EgressMarkedIPStore(fileURL: file)
        XCTAssertEqual(loaded.marker?.ip, "203.0.113.2")
        XCTAssertFalse(String(data: try Data(contentsOf: file), encoding: .utf8)!.contains("203.0.113.1"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try loaded.mark("999.1.1.1"))
        XCTAssertEqual(loaded.marker?.ip, "203.0.113.2")
        try loaded.clear()
        let cleared = EgressMarkedIPStore(fileURL: file)
        XCTAssertNil(cleared.marker); XCTAssertTrue(cleared.hasStoredState)
    }
    @MainActor func testLegacyMarkerRequiresOneUnambiguousHashAndBadFilesArePreserved() throws {
        let ip = "203.0.113.10", second = "203.0.113.20"
        let hash = try XCTUnwrap(EgressProbeResult(kind: .terminal, ip: ip).fingerprint)
        let other = try XCTUnwrap(EgressProbeResult(kind: .terminal, ip: second).fingerprint)
        XCTAssertEqual(EgressMarkedIPStore.legacyCandidate(fingerprints: [hash], knownIPs: [ip, second]), ip)
        XCTAssertNil(EgressMarkedIPStore.legacyCandidate(fingerprints: [hash, other], knownIPs: [ip, second]))
        XCTAssertNil(EgressMarkedIPStore.legacyCandidate(fingerprints: [hash], knownIPs: [second]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("marker.json")
        let original = Data("invalid data".utf8)
        try SubscriptionStorage.privateWrite(original, to: file)
        let store = EgressMarkedIPStore(fileURL: file)
        XCTAssertNotNil(store.warning)
        XCTAssertThrowsError(try store.mark(ip))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    @MainActor func testModelNormalizesComparisonAndMarkerChangeOverridesGreenNetworkResult() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EgressCheckModel(history: .init(fileURL: folder.appendingPathComponent("history.json")))
        model.results["claude.ai"] = [.terminal: .init(kind: .terminal, ip: "203.0.113.1", country: "US"), .ipv4: .init(kind: .ipv4, ip: "203.0.113.2", country: "US")]
        model.markIP("203.0.113.1")
        XCTAssertTrue(model.markedIPChanged)
        model.results["claude.ai"]?[.terminal]?.ip = "203.0.113.2"
        XCTAssertEqual(model.summary, "出口与标记 IP 不一致")
        model.markIP("203.0.113.2")
        model.previousIPs[model.resultKey("claude.ai", .terminal)] = "203.0.113.1"
        XCTAssertFalse(model.hasChanged)
        XCTAssertFalse(model.markedIPChanged)
        XCTAssertEqual(model.summary, "已检测的出口一致")
        model.clearMarkedIP(); XCTAssertNil(model.markedIP)
        model.results["claude.ai"] = [.terminal: .init(kind: .terminal, ip: "2001:0DB8::1", country: "US")]
        model.markIP("2001:db8::1")
        XCTAssertFalse(model.markedIPChanged)
        XCTAssertEqual(model.markedIP, "2001:db8::1")
    }
}
