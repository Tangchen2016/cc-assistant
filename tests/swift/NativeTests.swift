import XCTest
import Yams
@testable import SubscriptionStudio

final class NativeTests: XCTestCase {
    let link = "vless://11111111-2222-4333-8444-555555555555@node.example.com:443?encryption=none&security=tls&type=ws&sni=node.example.com&host=node.example.com&path=%2Fsocket#Synthetic"
    var source: [String: Any] { ["proxies": [["name": "HK", "type": "ss", "server": "node.example.com", "port": 443, "cipher": "aes-128-gcm", "password": "synthetic"], ["name": "JP", "type": "ss"]], "proxy-groups": [["name": "General", "type": "select", "proxies": ["HK", "JP", "DIRECT"]]], "rules": ["MATCH,General"]] }
    var profile: SubscriptionProfile { .init(name: "增强-测试", sourceUrl: "https://example.com/sub", groups: [.init(name: "Claude", nodes: [], chain: .init(entry: "General"), fixedExit: link)], rules: [.init(type: "DOMAIN-SUFFIX", value: "claude.ai", group: "Claude")]) }
    func testMobileGuideKeepsCredentialsInFragment() throws {
        let address = "https://node.tangchen02.top/remote-sub/" + String(repeating: "a", count: 32) + "/" + String(repeating: "b", count: 64) + "/%E5%A2%9E%E5%BC%BA.yaml"
        let name = "增强-测试 & 日本 / + # ?"
        let value = try XCTUnwrap(SubscriptionMobileImport.guide(address: address, name: name))
        let url = try XCTUnwrap(URLComponents(string: value))
        XCTAssertNil(url.query)
        XCTAssertEqual(url.path, "/apps/cc-assistant/import/")
        let fragment = try XCTUnwrap(url.percentEncodedFragment)
        let parts = try XCTUnwrap(URLComponents(string: "https://example.com/?" + fragment))
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "url" })?.value, address)
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "name" })?.value, name)
        XCTAssertTrue(try XCTUnwrap(SubscriptionMobileImport.exportURL(address: address, format: "shadowrocket-module")).hasSuffix("?format=shadowrocket-module"))
        XCTAssertNil(SubscriptionMobileImport.guide(address: "https://example.com/remote-sub/id/key", name: name))
    }
    func testShadowrocketScanContainsSubscriptionRatherThanGuidePage() throws {
        let prefix = "https://node.tangchen02.top/remote-sub/" + String(repeating: "a", count: 32) + "/" + String(repeating: "b", count: 64)
        let address = prefix + "/original.yaml"
        let name = "增强-测试 & 日本 / + # ?"
        let value = try XCTUnwrap(SubscriptionMobileImport.nodes(address: address, name: name))
        XCTAssertTrue(value.hasPrefix("sub://"))
        let parts = value.dropFirst(6).components(separatedBy: "?remark=")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(String(data: try XCTUnwrap(Data(base64Encoded: parts[0])), encoding: .utf8), prefix + "/claude-nodes.txt?format=shadowrocket-nodes")
        XCTAssertEqual(parts[1].removingPercentEncoding, name + " · Claude 节点")
        XCTAssertFalse(value.contains("#"))
        XCTAssertNil(SubscriptionMobileImport.nodes(address: "https://node.tangchen02.top/other", name: name))
        XCTAssertNil(SubscriptionMobileImport.nodes(address: address + "?format=other", name: name))
    }
    func testFixedExitAndUDPGuard() throws {
        let result = try SubscriptionCore.parse(SubscriptionCore.transform(source, profile: profile))
        let proxies = try XCTUnwrap(result["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.count, 3)
        XCTAssertEqual(proxies[2]["dialer-proxy"] as? String, "General")
        XCTAssertEqual(proxies[2]["server"] as? String, "node.example.com")
        XCTAssertNil(proxies[0]["dialer-proxy"])
        XCTAssertEqual(result["rules"] as? [String], ["AND,((DOMAIN-SUFFIX,claude.ai),(NETWORK,UDP)),REJECT", "DOMAIN-SUFFIX,claude.ai,Claude", "MATCH,General"])
    }
    @MainActor func testStandaloneMobileProfilesPersistAndStaySeparateFromClash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SubscriptionStorage(directory: directory)
        let clash = try storage.save(profile, id: nil)
        var mobile = SubscriptionProfile.mobile
        mobile.groups[0].fixedExit = link
        try SubscriptionCore.validate(mobile)
        let saved = try storage.save(mobile, id: nil)
        let loaded = SubscriptionStorage(directory: directory)
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.state.records.first?.profile.client, "shadowrocket")
        XCTAssertEqual(loaded.state.records.last?.downloadKey, clash.downloadKey)
        let model = SubscriptionModel(storage: loaded)
        XCTAssertEqual(model.visibleRecords.map(\.id), [clash.id])
        model.selectClient("shadowrocket")
        XCTAssertEqual(model.visibleRecords.map(\.id), [saved.id])
        model.open(saved)
        XCTAssertEqual(model.stage, "configure")
        XCTAssertNil(model.source)
        XCTAssertEqual(model.profile.sourceUrl, "")
        XCTAssertThrowsError(try SubscriptionCore.transform(source, profile: mobile))
        mobile.sourceUrl = "https://example.com/sub"
        XCTAssertThrowsError(try SubscriptionCore.validate(mobile))
        mobile.sourceUrl = ""; mobile.groups[0].chain = .init(entry: "HK")
        XCTAssertThrowsError(try SubscriptionCore.validate(mobile))
        let address = "https://node.tangchen02.top/remote-sub/" + String(repeating: "a", count: 32) + "/" + String(repeating: "b", count: 64) + "/claude-nodes.txt"
        XCTAssertTrue(try XCTUnwrap(SubscriptionMobileImport.guide(address: address, name: "mobile", standalone: true)).hasSuffix("&mode=shadowrocket"))
    }
    func testMissingFrontRejectsWithoutFallback() throws {
        var s = source; s["proxy-groups"] = []
        let result = try SubscriptionCore.parse(SubscriptionCore.transform(s, profile: profile))
        XCTAssertEqual((result["proxy-groups"] as? [[String: Any]])?.last?["proxies"] as? [String], ["REJECT"])
    }
    func testCycleAndNameCollisionReject() throws {
        var s = source; s["proxy-groups"] = [["name": "General", "type": "select", "proxies": ["General"]]]
        XCTAssertThrowsError(try SubscriptionCore.transform(s, profile: profile))
        s = source; s["proxy-groups"] = [["name": "Claude", "type": "select", "proxies": ["HK"]]]
        XCTAssertThrowsError(try SubscriptionCore.transform(s, profile: profile))
    }
    func testSubscriptionChainPreservesOriginal() throws {
        var p = profile; p.groups = [.init(name: "Claude", nodes: ["HK"], chain: .init(entry: "JP"))]
        let result = try SubscriptionCore.parse(SubscriptionCore.transform(source, profile: p))
        let proxies = try XCTUnwrap(result["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.last?["dialer-proxy"] as? String, "JP")
        XCTAssertNil(proxies.first?["dialer-proxy"])
        XCTAssertEqual(result["rules"] as? [String], ["DOMAIN-SUFFIX,claude.ai,Claude", "MATCH,General"])
    }
    func testUnsafeFixedExitAndSourcesReject() {
        for value in [link.replacingOccurrences(of: "type=ws", with: "type=tcp"), link + "&allowInsecure=1", link.replacingOccurrences(of: "node.example.com", with: "127.0.0.1"), link.replacingOccurrences(of: "security=tls", with: "security=none")] {
            // Fragment text is a label, not a query parameter.
            if value.hasSuffix("#Synthetic&allowInsecure=1") { continue }
            XCTAssertThrowsError(try SubscriptionCore.fixedExit(value))
        }
        XCTAssertThrowsError(try SubscriptionCore.fixedExit(link.replacingOccurrences(of: "#Synthetic", with: "&allowInsecure=1")))
        for url in ["http://127.0.0.1/", "http://192.168.1.1/", "http://[::1]/", "https://localhost/", "file:///tmp/config", "https://user:pass@example.com/"] { XCTAssertThrowsError(try SubscriptionCore.publicURL(url)) }
    }
    func testYAMLRejectsDuplicateAndAliasExpansion() throws {
        XCTAssertThrowsError(try SubscriptionCore.parse("proxies: []\nproxies: []\n"))
        XCTAssertThrowsError(try SubscriptionCore.parse("a: &a [*a]\nproxies: []\n"))
        let yaml = "defaults: &base {type: ss}\nproxies:\n - {name: HK, type: ss}\nproxy-groups: []\nrules: [MATCH,DIRECT]\n"
        XCTAssertNotNil(try SubscriptionCore.parse(yaml)["proxies"])
    }
    @MainActor func testLegacyMigrationKeepsKeysAndDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = SubscriptionRecord(id: String(repeating: "a", count: 32), manageKey: String(repeating: "b", count: 64), downloadKey: String(repeating: "c", count: 64), profile: profile, updatedAt: 1700000000000)
        var state = SubscriptionState(); state.records = [record]; state.currentId = record.id; state.draft = profile
        let original = try JSONEncoder().encode(state)
        try SubscriptionStorage.privateWrite(original, to: root.appendingPathComponent("profiles.json"))
        let store = SubscriptionStorage(directory: root)
        var migrated = try XCTUnwrap(store.state.records.first)
        XCTAssertNotNil(migrated.profile.groups[0].staticNodeId)
        XCTAssertEqual(store.state.draft?.groups[0].staticNodeId, migrated.profile.groups[0].staticNodeId)
        migrated.profile.groups[0].staticNodeId = nil
        XCTAssertEqual(migrated, record)
        var migratedDraft = try XCTUnwrap(store.state.draft); migratedDraft.groups[0].staticNodeId = nil
        XCTAssertEqual(migratedDraft, profile)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profiles.before-swift.json")), original)
        var changed = profile; changed.name = "新名字"
        let updated = try store.save(changed, id: record.id)
        XCTAssertEqual(updated.downloadKey, record.downloadKey); XCTAssertEqual(updated.manageKey, record.manageKey)
        XCTAssertTrue(updated.localURL.contains("/sub/\(record.id)/\(record.downloadKey)/"))
        let again = SubscriptionStorage(directory: root); XCTAssertEqual(again.state.records.first?.profile.name, "新名字")
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("profiles.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    @MainActor func testCorruptStoreCannotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("corrupt".utf8); try SubscriptionStorage.privateWrite(bytes, to: root.appendingPathComponent("profiles.json"))
        let store = SubscriptionStorage(directory: root)
        XCTAssertNotNil(store.error); XCTAssertThrowsError(try store.save(profile, id: nil))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profiles.json")), bytes)
    }
    @MainActor func testLoopbackHTTPAndPortConflictIsolation() async throws {
        let server = SubscriptionServer(port: 0)
        let id = String(repeating: "a", count: 32), key = String(repeating: "b", count: 64)
        server.download = { suppliedID, suppliedKey in guard suppliedID == id && SubscriptionModel.equalSecret(suppliedKey, key) else { throw SubscriptionFailure("invalid") }; return ("rules: [MATCH,REJECT]\n", "配置", nil) }
        server.start(); defer { server.stop() }
        for _ in 0..<50 { if server.ready { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(server.ready)
        let url = URL(string: "http://127.0.0.1:\(server.port)/sub/\(id)/\(key)/old-name.yaml")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("MATCH"))
        let (_, denied) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)/sub/\(id)/\(String(repeating: "c", count: 64))/x.yaml")!)
        XCTAssertNotEqual((denied as? HTTPURLResponse)?.statusCode, 200)
        let occupied = SubscriptionServer(port: server.port); occupied.start(); defer { occupied.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(occupied.ready); XCTAssertTrue(server.ready)
    }
    func testActualSubscriptionParityWhenProvided() throws {
        guard let root = ProcessInfo.processInfo.environment["CC_SWIFT_PARITY_DIR"] else { throw XCTSkip("Private real-subscription fixture not provided") }
        let directory = URL(fileURLWithPath: root)
        let source = try SubscriptionCore.parse(String(contentsOf: directory.appendingPathComponent("source.yaml"), encoding: .utf8))
        let profile = try JSONDecoder().decode(SubscriptionProfile.self, from: Data(contentsOf: directory.appendingPathComponent("profile.json")))
        let actual = try SubscriptionCore.parse(SubscriptionCore.transform(source, profile: profile))
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("expected.json"))) as! NSDictionary
        // Never print this comparison's contents: node credentials are private.
        XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected as! [AnyHashable: Any]), "Native transformation differs from legacy output")
    }

    func testActualSourceFetchWhenProvided() async throws {
        guard let root = ProcessInfo.processInfo.environment["CC_SWIFT_PARITY_DIR"] else { throw XCTSkip("Private fixture not provided") }
        let profile = try JSONDecoder().decode(SubscriptionProfile.self, from: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("profile.json")))
        let source = try await SubscriptionNetwork.fetch(profile.sourceUrl)
        XCTAssertFalse(source.nodes.isEmpty)
        let converted = try SubscriptionCore.parse(SubscriptionCore.transform(source.config, profile: profile))
        XCTAssertTrue((converted["rules"] as? [String])?.contains(where: { $0.contains("NETWORK,UDP") && $0.hasSuffix("REJECT") }) == true)
    }
    func testRemoteContractWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CC_SWIFT_REMOTE_VERIFY"] == "1" else { throw XCTSkip("Live remote verification not enabled") }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        let payload = try JSONSerialization.data(withJSONObject: ["profile": object, "sourceYaml": Yams.dump(object: source), "sourceFetchedAt": ISO8601DateFormatter().string(from: Date())])
        let created = try await SubscriptionNetwork.remoteRequest(origin: SubscriptionNetwork.remoteOrigin, path: "/api/remote-subscriptions", method: "POST", key: nil, body: payload)
        let id = try XCTUnwrap(created["id"] as? String), key = try XCTUnwrap(created["manageKey"] as? String), path = try XCTUnwrap(created["subscriptionPath"] as? String)
        do {
            let (data, response) = try await SubscriptionNetwork.request(URLRequest(url: URL(string: SubscriptionNetwork.remoteOrigin + path)!))
            XCTAssertEqual(response.statusCode, 200)
            let result = try SubscriptionCore.parse(String(data: data, encoding: .utf8)!)
            XCTAssertTrue((result["rules"] as? [String])?.first?.contains("NETWORK,UDP") == true)
        } catch {
            _ = try? await SubscriptionNetwork.remoteRequest(origin: SubscriptionNetwork.remoteOrigin, path: "/api/remote-subscriptions/" + id, method: "DELETE", key: key, body: nil)
            throw error
        }
        _ = try await SubscriptionNetwork.remoteRequest(origin: SubscriptionNetwork.remoteOrigin, path: "/api/remote-subscriptions/" + id, method: "DELETE", key: key, body: nil)
    }

}
