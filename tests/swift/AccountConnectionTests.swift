import XCTest
import Network
import Darwin
@testable import SubscriptionStudio

final class AccountConnectionTests: XCTestCase {
    private let token = "test-session-not-a-real-credential"
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func stopTestProcess(_ process: Process) {
        if process.isRunning { process.terminate() }
        for _ in 0..<30 where process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
    }
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("cc-connection-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }; return value
    }
    private func identity(_ email: String = "first@example.invalid", plan: String? = "Pro") -> AccountIdentitySnapshot {
        .init(email: email, accountID: "account-example", name: "测试", plan: plan, planIsInferred: false, checkedAt: date)
    }
    @MainActor private func model() throws -> AccountPoolModel { AccountPoolModel(store: AccountPoolStore(fileURL: try directory().appendingPathComponent("accounts.json"))) }
    @MainActor private func awaitIdle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if !condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Operation did not finish")
    }

    func testSessionHeaderAndFixedDestinationRejectInjection() throws {
        XCTAssertEqual(try AccountIdentityParser.sessionKey(" sessionKey=\(token) "), token)
        for input in ["short", token + "\r\nX-Header: injection", token + "; other=value", "https://example.com/" + token] {
            XCTAssertThrowsError(try AccountSessionClient.request(input))
        }
        let request = try AccountSessionClient.request(token)
        XCTAssertEqual(request.url?.absoluteString, "https://claude.ai/api/account")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=\(token)")
        XCTAssertThrowsError(try AccountSessionClient.proxyDictionary("http://user:secret@127.0.0.1:7890"))
        XCTAssertThrowsError(try AccountSessionClient.proxyDictionary("https://127.0.0.1:7890"))
        let proxy = try XCTUnwrap(AccountSessionClient.proxyDictionary("http://127.0.0.1:7890"))
        XCTAssertEqual(proxy["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(proxy["HTTPSPort"] as? Int, 7890)
    }
    func testIdentityParsingDoesNotGuessDatesOrAmbiguousPlans() throws {
        let data = Data(#"{"email_address":"First@Example.Invalid","uuid":"account-example","full_name":"示例","expiresAt":9999999999999,"memberships":[{"organization":{"rate_limit_tier":"default_claude_max_5x"}}]}"#.utf8)
        let found = try AccountIdentityParser.parse(data, now: date)
        XCTAssertEqual(found.email, "first@example.invalid")
        XCTAssertEqual(found.plan, "Max 5x"); XCTAssertTrue(found.planIsInferred); XCTAssertNil(found.remoteCreatedAt)
        let multiple = Data(#"{"email_address":"first@example.invalid","memberships":[{"organization":{"rate_limit_tier":"default_claude_pro"}},{"organization":{"rate_limit_tier":"default_claude_max_5x"}}]}"#.utf8)
        XCTAssertNil(try AccountIdentityParser.parse(multiple).plan)
        XCTAssertNil(try AccountIdentityParser.parse(Data(#"{"email_address":"first@example.invalid"}"#.utf8)).plan)
        XCTAssertThrowsError(try AccountIdentityParser.parse(Data(#"{"full_name":"No email"}"#.utf8)))
        XCTAssertThrowsError(try AccountIdentityParser.parse(Data("<html>verification</html>".utf8)))
        XCTAssertThrowsError(try AccountIdentityParser.parse(Data(repeating: 32, count: 262145)))
        XCTAssertThrowsError(try AccountIdentityParser.checkStatus(401)) { XCTAssertEqual($0 as? AccountConnectionError, .unauthorized) }
        XCTAssertThrowsError(try AccountIdentityParser.checkStatus(403)) { XCTAssertEqual($0 as? AccountConnectionError, .restricted) }
        XCTAssertThrowsError(try AccountIdentityParser.checkStatus(302)) { XCTAssertEqual($0 as? AccountConnectionError, .redirect) }
    }
    @MainActor func testIdentityUpsertPreservesManualFieldsAndRejectsMismatchedTarget() throws {
        let model = try model(), expiry = date.addingTimeInterval(86400)
        let old = try model.store.save(.init(email: identity().email, label: "手动备注名", status: .attention, subscription: "手填套餐", expiresAt: expiry, createdAt: date, notes: "保留"), now: date)
        let saved = try model.store.acceptIdentity(identity(), targetID: old.id)
        XCTAssertEqual(saved.id, old.id); XCTAssertEqual(saved.status, .attention); XCTAssertEqual(saved.label, "手动备注名")
        XCTAssertEqual(saved.notes, "保留"); XCTAssertEqual(saved.expiresAt, expiry); XCTAssertEqual(saved.createdAt, date)
        XCTAssertEqual(saved.subscription, "Pro")
        let unknown = try model.store.acceptIdentity(identity(plan: nil))
        XCTAssertEqual(unknown.subscription, "Pro"); XCTAssertEqual(model.store.records.count, 1)
        let before = try Data(contentsOf: model.store.fileURL)
        XCTAssertThrowsError(try model.store.acceptIdentity(identity("other@example.invalid"), targetID: old.id))
        XCTAssertEqual(try Data(contentsOf: model.store.fileURL), before)
        try model.store.delete(old.id)
        XCTAssertThrowsError(try model.store.acceptIdentity(identity()))
    }
    @MainActor func testPrivateConnectionIsExcludedFromAccountExportAndPermissionProtected() throws {
        let model = try model(), record = try model.store.acceptIdentity(identity())
        let connection = AccountConnection(kind: .session, email: record.email, sessionKey: token)
        try model.connections.save(connection, for: record.id)
        XCTAssertEqual(try model.connections.load(record.id), connection)
        let file = model.connections.directory.appendingPathComponent(record.id.uuidString.lowercased() + ".json")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let backup = String(decoding: try model.store.backupData(), as: UTF8.self)
        XCTAssertFalse(backup.contains(token)); XCTAssertFalse(backup.contains("sessionKey"))
        // A backup round-trip also works while in-memory dates still include fractions.
        XCTAssertEqual(try model.store.importData(model.store.backupData()), 0)
        try model.connections.remove(record.id); XCTAssertFalse(model.connections.exists(record.id))
        XCTAssertEqual(model.store.records.count, 1)
    }
    @MainActor func testCorruptAndSymlinkedConnectionFilesAreNotFollowed() throws {
        let root = try directory(), id = UUID(), vault = AccountConnectionStore(directory: root.appendingPathComponent("private"))
        try vault.save(.init(kind: .session, email: identity().email, sessionKey: token), for: id)
        let file = vault.directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
        let corrupt = Data("invalid credential file".utf8); try corrupt.write(to: file)
        XCTAssertThrowsError(try vault.load(id)); XCTAssertEqual(try Data(contentsOf: file), corrupt)
        try FileManager.default.removeItem(at: file)
        let other = root.appendingPathComponent("other.json"); try Data("unrelated".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertThrowsError(try vault.load(id))
        XCTAssertThrowsError(try vault.save(.init(kind: .session, email: identity().email, sessionKey: token), for: id))
        XCTAssertEqual(try Data(contentsOf: other), Data("unrelated".utf8))
    }
    @MainActor func testRegisterRequiresMatchingEmailBeforeConfirmingAccount() async throws {
        let model = try model(), found = identity(), token = token
        model.connectionFlow.sessionReader = { _, _ in .init(identity: found, sessionKey: token) }
        model.beginConnection(.register)
        model.connectionFlow.sessionInput = token; model.connectionFlow.read()
        XCTAssertFalse(model.connectionFlow.busy); XCTAssertNil(model.connectionFlow.candidate)
        model.connectionFlow.expectedEmail = "other@example.invalid"; model.connectionFlow.read()
        try await awaitIdle { model.connectionFlow.busy }
        XCTAssertNil(model.connectionFlow.candidate); XCTAssertTrue(model.records.isEmpty)
        model.connectionFlow.expectedEmail = found.email; model.connectionFlow.read()
        try await awaitIdle { model.connectionFlow.busy }
        XCTAssertNotNil(model.connectionFlow.candidate)
        model.acceptConnection()
        XCTAssertEqual(model.records.count, 1); XCTAssertFalse(model.showConnection)
        XCTAssertEqual(try model.connections.load(model.records[0].id).sessionKey, token)
    }
    @MainActor func testExistingAccountWithoutRememberingSessionAndCancelledRead() async throws {
        let model = try model(), found = identity(), token = token
        model.connectionFlow.sessionReader = { _, _ in .init(identity: found, sessionKey: token) }
        model.beginConnection(.existing); model.connectionFlow.source = .session; model.connectionFlow.sessionInput = token
        model.connectionFlow.rememberSession = false; model.connectionFlow.read()
        try await awaitIdle { model.connectionFlow.busy }; model.acceptConnection()
        XCTAssertEqual(model.records.count, 1); XCTAssertFalse(model.connections.exists(model.records[0].id))
        model.beginConnection(.existing)
        model.connectionFlow.sessionReader = { _, _ in
            try await Task.sleep(nanoseconds: 100_000_000); return .init(identity: found, sessionKey: token)
        }
        model.connectionFlow.sessionInput = token; model.connectionFlow.read(); model.cancelConnection()
        try await Task.sleep(nanoseconds: 130_000_000)
        XCTAssertNil(model.connectionFlow.candidate); XCTAssertFalse(model.connectionFlow.busy)
    }
    @MainActor func testBrowserMetadataLinkHasNoSessionAndSessionModeDoesNotEnableBrowserConnection() async throws {
        let model = try model(), found = identity(), profile = UUID()
        var enabled: [Bool] = []
        model.connectionFlow.openBrowser = { enabled.append($0) }
        model.beginConnection(.existing); model.connectionFlow.openOfficialPage()
        XCTAssertEqual(enabled, [false])
        model.connectionFlow.browserProfile = { profile }
        model.connectionFlow.browserReader = { found }
        model.beginConnection(.register, email: found.email); model.connectionFlow.openOfficialPage()
        XCTAssertEqual(enabled, [false, true])
        model.connectionFlow.read(); try await awaitIdle { model.connectionFlow.busy }; model.acceptConnection()
        let row = try XCTUnwrap(model.records.first), connection = try model.connections.load(row.id)
        XCTAssertEqual(connection.kind, .browser); XCTAssertEqual(connection.profileID, profile); XCTAssertNil(connection.sessionKey)
        XCTAssertThrowsError(try model.connections.save(.init(kind: .browser, email: found.email, profileID: profile, sessionKey: token), for: row.id))
        XCTAssertEqual(try model.connections.load(row.id), connection)
    }
    @MainActor func testDisconnectDuringRefreshCannotRestoreOldCredential() async throws {
        let model = try model(), found = identity(), token = token
        let record = try model.store.acceptIdentity(found); try model.importData(model.store.backupData())
        try model.connections.save(.init(kind: .session, email: record.email, sessionKey: token), for: record.id)
        model.connectionFlow.sessionReader = { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000); return .init(identity: found, sessionKey: token)
        }
        model.refresh(record)
        try await Task.sleep(nanoseconds: 15_000_000)
        model.disconnect(record)
        try await awaitIdle { model.refreshing.contains(record.id) }
        XCTAssertFalse(model.connections.exists(record.id))
        XCTAssertEqual(model.records.count, 1)
    }
    @MainActor func testUnauthorizedRefreshMarksSessionInvalidAndSuccessRestores() async throws {
        let model = try model(), found = identity(), token = token
        var row = try model.store.acceptIdentity(found)
        var draft = row.draft; draft.status = .inUse; row = try model.store.save(draft, id: row.id)
        try model.connections.save(.init(kind: .session, email: row.email, sessionKey: token), for: row.id)
        try model.importData(model.store.backupData())
        model.accountSessionProxy = { _ in nil }
        model.connectionFlow.sessionReader = { _, _ in throw AccountConnectionError.restricted }
        model.refresh(row); try await awaitIdle { !model.refreshing.isEmpty }
        XCTAssertNil(model.records[0].sessionInvalidFrom, "403 must not mark the session dead")
        model.connectionFlow.sessionReader = { _, _ in throw AccountConnectionError.unauthorized }
        model.refresh(row); try await awaitIdle { !model.refreshing.isEmpty }
        XCTAssertEqual(model.records[0].status, .attention); XCTAssertEqual(model.records[0].sessionInvalidFrom, .inUse)
        XCTAssertEqual(model.invalidSessionCount, 1)
        model.connectionFlow.sessionReader = { _, _ in .init(identity: found, sessionKey: token) }
        model.refresh(row); try await awaitIdle { !model.refreshing.isEmpty }
        XCTAssertEqual(model.records[0].status, .inUse); XCTAssertNil(model.records[0].sessionInvalidFrom)
    }
    @MainActor func testBatchImportReadsDedupesAndSaves() async throws {
        let model = try model()
        let keys = (0..<4).map { "batch-session-key-\($0)-not-real" }
        model.connectionFlow.sessionReader = { key, _ in
            guard let index = keys.firstIndex(of: key) else { throw AccountConnectionError.unauthorized }
            // keys 2 and 3 resolve to the same account
            return .init(identity: self.identity("b\(min(index, 2))@example.invalid"), sessionKey: key)
        }
        model.beginBatch()
        model.batchInput = keys.joined(separator: "\n") + "\n\(keys[0])\nsessionKey=\(keys[1])\nbad key\nunknown-session-key-xxxxxx"
        model.readBatch()
        try await awaitIdle { model.batchBusy }
        XCTAssertEqual(model.batchItems.count, 6)  // 4 unique + bad format + unknown
        XCTAssertEqual(model.batchReadyCount, 3)
        model.saveBatch()
        XCTAssertEqual(model.activeRecords.count, 3)
        XCTAssertTrue(model.activeRecords.allSatisfy { model.connections.exists($0.id) })
        XCTAssertEqual(model.batchReadyCount, 0, "saved rows cannot be saved twice")
    }
    @MainActor func testFreshClaudeLaunchGoesThroughExitCheck() throws {
        XCTAssertEqual(RegistrationModel.launchPage(for: "https://claude.ai/"), RegistrationModel.browserCheckThenClaudePage)
        XCTAssertEqual(RegistrationModel.launchPage(for: RegistrationModel.browserCheckPage), RegistrationModel.browserCheckPage)
        XCTAssertEqual(RegistrationModel.launchPage(for: "https://claude.ai/settings/billing"), "https://claude.ai/settings/billing")
        XCTAssertTrue(RegistrationModel.browserCheckThenClaudePage.hasSuffix("&then=claude"))
    }
    @MainActor func testBatchRefreshCapsConcurrency() async throws {
        let model = try model(), token = token
        final class Counter: @unchecked Sendable { let lock = NSLock(); var now = 0, peak = 0, done = 0 }
        let counter = Counter()
        for index in 0..<7 {
            let row = try model.store.acceptIdentity(identity("u\(index)@example.invalid"))
            try model.connections.save(.init(kind: .session, email: row.email, sessionKey: token), for: row.id)
        }
        try model.importData(model.store.backupData())
        model.accountSessionProxy = { _ in nil }
        model.connectionFlow.sessionReader = { _, _ in
            counter.lock.lock(); counter.now += 1; counter.peak = max(counter.peak, counter.now); counter.lock.unlock()
            try await Task.sleep(nanoseconds: 20_000_000)
            counter.lock.lock(); counter.now -= 1; counter.done += 1; counter.lock.unlock()
            throw AccountConnectionError.network
        }
        model.refreshAll()
        XCTAssertEqual(model.refreshing.count, 7)
        try await awaitIdle { !model.refreshing.isEmpty }
        XCTAssertEqual(counter.done, 7)
        XCTAssertLessThanOrEqual(counter.peak, AccountPoolModel.refreshConcurrency)
    }
    func testBrowserConnectionOnlyUsesLoopbackAndExactOfficialOrigin() throws {
        let url = try BrowserAccountReader.socketURL("45678\n/devtools/browser/abcd-1234\n")
        XCTAssertEqual(url.host, "127.0.0.1")
        for input in ["0\n/devtools/browser/a", "45678\n//evil.example/x", "45678\n/devtools/browser/a?redirect=https://evil.example", "45678\n/devtools/browser/a\nextra"] {
            XCTAssertThrowsError(try BrowserAccountReader.socketURL(input))
        }
        XCTAssertTrue(BrowserAccountReader.isClaudePage(["type": "page", "url": "https://claude.ai/new"]))
        for value in ["http://claude.ai/", "https://claude.ai.evil.example/", "https://claude.ai:8443/", "https://user@claude.ai/"] {
            XCTAssertFalse(BrowserAccountReader.isClaudePage(["type": "page", "url": value]))
        }
    }
    func testHTTPReadUsesOfficialCookieAndClassifiesFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AccountMockProtocol.self]
        AccountMockProtocol.configure(status: 200, body: #"{"email_address":"first@example.invalid","subscription_type":"pro"}"#)
        let reading = try await AccountSessionClient.read(token, configuration: configuration)
        XCTAssertEqual(reading.identity.email, "first@example.invalid"); XCTAssertEqual(reading.identity.plan, "Pro")
        XCTAssertEqual(AccountMockProtocol.lastRequest()?.value(forHTTPHeaderField: "Cookie"), "sessionKey=\(token)")
        AccountMockProtocol.configure(status: 403, body: "<html>blocked</html>")
        do { _ = try await AccountSessionClient.read(token, configuration: configuration); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? AccountConnectionError, .restricted) }
        AccountMockProtocol.configure(status: 302, body: "")
        do { _ = try await AccountSessionClient.read(token, configuration: configuration); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? AccountConnectionError, .redirect) }
    }
    func testRedirectDelegateNeverForwardsCredentials() {
        let blocker = AccountRedirectBlocker(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URLRequest(url: AccountSessionClient.endpoint)
        let response = HTTPURLResponse(url: AccountSessionClient.endpoint, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://example.invalid"])!
        blocker.urlSession(session, task: session.dataTask(with: original), willPerformHTTPRedirection: response,
                           newRequest: URLRequest(url: URL(string: "https://example.invalid")!)) { XCTAssertNil($0) }
    }
    func testConnectionToEmptyIsolatedChromeDoesNotReadOtherProfiles() async throws {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chrome.path) else { throw XCTSkip("Chrome is not installed") }
        let root = try directory(), profile = root.appendingPathComponent("profile")
        let process = Process(); process.executableURL = chrome
        process.arguments = ["--headless=new", "--user-data-dir=\(profile.path)", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0", "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--disable-sync", "about:blank"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { stopTestProcess(process) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: profile.appendingPathComponent("DevToolsActivePort").path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        do { _ = try await BrowserAccountReader.read(profile: profile); XCTFail("There is no signed-in Claude page") }
        catch { XCTAssertTrue(error.localizedDescription.contains("打开 claude.ai"), "Expected a connected browser with no Claude target, got \(error.localizedDescription)") }
    }
    func testSessionHTTPSRequestUsesConfiguredHTTPProxy() async throws {
        let listener = try NWListener(using: .tcp, on: .any), ready = expectation(description: "proxy ready"), received = expectation(description: "CONNECT observed")
        let capture = ProxyRequestCapture()
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                capture.set(data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? "")
                received.fulfill()
                connection.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global()); defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port).rawValue
        do { _ = try await AccountSessionClient.read(token, proxy: "http://127.0.0.1:\(port)"); XCTFail("Test proxy deliberately rejects the tunnel") }
        catch { XCTAssertNotNil(error as? AccountConnectionError) }
        await fulfillment(of: [received], timeout: 3)
        XCTAssertTrue(capture.get().hasPrefix("CONNECT claude.ai:443 "), "HTTPS request must use the configured proxy")
    }
}

private final class ProxyRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var line = ""
    func set(_ value: String) { lock.lock(); defer { lock.unlock() }; line = value }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return line }
}

private final class AccountMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseStatus = 200
    private static var responseBody = ""
    private static var received: URLRequest?
    static func configure(status: Int, body: String) { lock.lock(); defer { lock.unlock() }; responseStatus = status; responseBody = body; received = nil }
    static func lastRequest() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return received }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let status = Self.responseStatus, body = Self.responseBody; Self.received = request; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
