import SwiftUI

enum AccountConnectionIntent: String { case register, existing }
enum AccountConnectionSource: String, CaseIterable { case browser = "独立浏览器", session = "Session" }
struct AccountReadCandidate {
    let identity: AccountIdentitySnapshot
    let connection: AccountConnection
}

@MainActor final class AccountConnectionFlow: ObservableObject {
    @Published private(set) var intent: AccountConnectionIntent = .existing
    @Published var source: AccountConnectionSource = .session { didSet { invalidate() } }
    @Published var expectedEmail = "" { didSet { invalidate() } }
    @Published var sessionInput = "" { didSet { invalidate() } }
    @Published var rememberSession = true
    @Published private(set) var candidate: AccountReadCandidate?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private(set) var targetID: UUID?
    var prepareBrowser: ((String) throws -> Void)?
    var openBrowser: ((Bool) -> Void)?
    var browserReader: (() async throws -> AccountIdentitySnapshot)?
    var browserProfile: (() -> UUID)?
    var sessionProxyForEmail: ((String) throws -> String?)?
    var sessionProxy: () throws -> String? = { nil }
    var sessionReader: (String, String?) async throws -> AccountSessionReading = { try await AccountSessionClient.read($0, proxy: $1) }
    private var requestID = UUID()
    private var readingTask: Task<Void, Never>?
    var browserAvailable: Bool { browserReader != nil && browserProfile != nil }
    var title: String { intent == .register ? "注册新账号并入库" : "接入已有账号" }
    var hasPendingInput: Bool { busy || candidate != nil || !sessionInput.isEmpty || !expectedEmail.isEmpty }
    func begin(_ intent: AccountConnectionIntent, row: AccountPoolRecord? = nil, email: String = "") {
        cancel(); self.intent = intent; targetID = row?.id
        expectedEmail = row?.email ?? email
        source = browserAvailable ? .browser : .session
        rememberSession = true; message = ""
    }
    private func invalidate() {
        requestID = UUID(); readingTask?.cancel(); readingTask = nil
        busy = false; candidate = nil; message = ""
    }
    func cancel() { invalidate(); sessionInput = ""; targetID = nil }
    func showError(_ error: Error) { message = error.localizedDescription }
    private func validatedExpected() throws -> String? {
        let value = expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            if intent == .register { throw SubscriptionFailure("请先填写准备注册的邮箱，避免误接入浏览器里已有的其他账号。") }
            return nil
        }
        return try AccountPoolStore.email(value)
    }
    func openOfficialPage() {
        do {
            let email = try validatedExpected()
            if source == .browser, let prepareBrowser {
                guard let email else { throw SubscriptionFailure("请填写账号邮箱，以选择对应的浏览器环境。") }
                try prepareBrowser(email)
            }
            openBrowser?(source == .browser)
            message = source == .browser ? "" : (intent == .register ? "请在官网完成注册、验证码与条款确认，再返回读取账号。" : "请在官网完成登录，再返回读取账号。")
        } catch { showError(error) }
    }
    func read() {
        guard !busy else { return }
        do {
            let expected = try validatedExpected()
            let selected = source, key = selected == .session ? try AccountIdentityParser.sessionKey(sessionInput) : nil
            let proxy: String?
            if selected == .session, let expected, let sessionProxyForEmail { proxy = try sessionProxyForEmail(expected) }
            else { proxy = selected == .session ? try sessionProxy() : nil }
            if selected == .browser, let prepareBrowser {
                guard let expected else { throw SubscriptionFailure("请填写账号邮箱，以选择对应的浏览器环境。") }
                try prepareBrowser(expected)
            }
            let profile = selected == .browser ? browserProfile?() : nil
            guard selected != .browser || browserAvailable else { throw AccountConnectionError.browser("此端请使用 Session 接入。") }
            let request = UUID(); requestID = request; busy = true; candidate = nil; message = "正在读取官网账号资料…"
            readingTask = Task { [weak self] in
                guard let self else { return }
                defer { if requestID == request { busy = false } }
                guard requestID == request, !Task.isCancelled else { return }
                do {
                    let result: AccountReadCandidate
                    if selected == .session, let key {
                        let reading = try await sessionReader(key, proxy)
                        result = .init(identity: reading.identity, connection: .init(kind: .session, email: reading.identity.email, sessionKey: reading.sessionKey))
                    } else {
                        guard let reader = browserReader, let profile else { throw AccountConnectionError.noConnection }
                        let identity = try await reader()
                        guard browserProfile?() == profile else { throw AccountConnectionError.changed }
                        result = .init(identity: identity, connection: .init(kind: .browser, email: identity.email, profileID: profile))
                    }
                    guard requestID == request, !Task.isCancelled else { return }
                    if let expected, result.identity.email != expected { throw AccountConnectionError.mismatch }
                    candidate = result; message = "已识别，请核对后确认加入号池。"
                } catch {
                    guard requestID == request, !Task.isCancelled else { return }
                    candidate = nil; showError(error)
                }
            }
        } catch { candidate = nil; showError(error) }
    }
}
