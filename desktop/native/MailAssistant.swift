import Foundation
import SwiftUI

struct MailAssistantSettings: Codable {
    var endpoint = ""
    var token = ""
    static var file: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Subscription Studio/private-mail/settings.json") }
    static func load() throws -> Self {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let data = try Data(contentsOf: file)
        guard data.count < 8192 else { throw SubscriptionFailure("邮件辅助配置过大。") }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validatedURL(_ path: String) throws -> URL {
        guard let url = URL(string: endpoint), url.scheme == "https", let host = url.host,
              !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              token.count >= 32, token.count <= 256, token.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw SubscriptionFailure("请填写 HTTPS 服务地址和有效访问密钥。")
        }
        return url.appendingPathComponent(path)
    }
    func save() throws {
        _ = try validatedURL("watch")
        let folder = Self.file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try SubscriptionStorage.privateWrite(JSONEncoder().encode(self), to: Self.file)
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var file = Self.file; try file.setResourceValues(resource)
    }
}

private final class MailNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct MailAssistantReply: Decodable {
    var id: String?
    var expiresAt: Double?
    var code: String?
    var loginURL: String?
    var receivedAt: Double?
    var email: String?
    var manual: Bool?
}

@MainActor final class MailAssistantModel: ObservableObject {
    @Published var settings = MailAssistantSettings()
    @Published private(set) var status = "点击等待后，再到官网发送验证码。"
    @Published private(set) var waiting = false
    @Published private(set) var code: String?
    @Published private(set) var loginURL: URL?
    @Published private(set) var receivedAt: Date?
    let localPage = LocalMailPage()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var sessionID: String?
    private var activeSettings: MailAssistantSettings?
    init(settings: MailAssistantSettings? = nil) {
        if let settings { self.settings = settings; return }
        do { self.settings = try .load() } catch { status = "邮件辅助配置无法读取，请重新配置。" }
    }
    func save() {
        stop()
        do { try settings.save(); status = "连接配置已保存到本机。" }
        catch { status = error.localizedDescription }
    }
    static func request(_ path: String, input: [String: String], settings: MailAssistantSettings) async throws -> MailAssistantReply {
        var request = URLRequest(url: try settings.validatedURL(path)); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(input)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: MailNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubscriptionFailure("邮件服务未返回有效响应。") }
        if http.statusCode == 401 { throw SubscriptionFailure("邮件服务访问密钥无效，请检查连接设置。") }
        if http.statusCode == 410 { throw SubscriptionFailure("本次等待已过期，请重新开始。") }
        guard http.statusCode == 200, data.count < 16384 else { throw SubscriptionFailure("邮件服务暂时无法读取，请稍后再试。") }
        return try JSONDecoder().decode(MailAssistantReply.self, from: data)
    }
    func start(email: String) {
        stop()
        do {
            let email = try AccountPoolStore.email(email)
            _ = try settings.validatedURL("watch")
            let current = generation, config = settings
            waiting = true; status = "正在开启邮件等待…"; activeSettings = config
            task = Task { [weak self] in
                guard let self else { return }
                defer { if generation == current { waiting = false } }
                do {
                    let result = try await Self.request("watch", input: ["email": email], settings: config)
                    guard let id = result.id, let remoteExpiry = result.expiresAt, remoteExpiry.isFinite else { throw SubscriptionFailure("邮件等待未能开启。") }
                    guard current == generation, !Task.isCancelled else {
                        _ = try? await Self.request("stop", input: ["id": id], settings: config); return
                    }
                    let expires = min(remoteExpiry, Date().timeIntervalSince1970 * 1000 + 600_000)
                    sessionID = id; status = "已开始等待，请在官网发送验证码（最长 10 分钟）。"
                    while Date().timeIntervalSince1970 * 1000 < expires {
                        try await Task.sleep(nanoseconds: 10_000_000_000)
                        let mail = try await Self.request("read", input: ["id": id], settings: config)
                        guard current == generation, !Task.isCancelled else { return }
                        if let address = mail.email, address != email { throw SubscriptionFailure("收件地址不匹配，请重新开始等待。") }
                        let validCode = mail.code.flatMap { $0.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil ? $0 : nil }
                        let validLink = mail.loginURL.flatMap { ClaudeMailLink.validated($0, email: email) }
                        if validCode != nil || validLink != nil {
                            code = validCode; loginURL = validLink; receivedAt = mail.receivedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
                            status = validLink != nil ? "已收到 Claude 登录链接，可在当前独立浏览器打开。" : "已提取验证码，请核对后复制。原邮件仍转发到 iCloud。"
                            _ = try? await Self.request("stop", input: ["id": id], settings: config)
                            sessionID = nil
                            let remaining = max(0, expires / 1000 - Date().timeIntervalSince1970)
                            waiting = false
                            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                            if current == generation { code = nil; loginURL = nil; receivedAt = nil; status = "登录凭据已清除，请按需重新等待。" }
                            return
                        }
                        if mail.manual == true { status = "已收到相关邮件，但未能唯一识别验证码或登录链接，请到 iCloud 查看。" }
                    }
                    if current == generation { status = "等待已结束，未读取到验证码。可检查 iCloud 后重新开始。" }
                } catch {
                    if current == generation, !Task.isCancelled { status = error.localizedDescription }
                }
            }
        } catch { status = error.localizedDescription }
    }
    func stop() {
        localPage.stop()
        generation = UUID(); task?.cancel(); task = nil; waiting = false; code = nil; loginURL = nil; receivedAt = nil
        if let id = sessionID, let config = activeSettings { Task { _ = try? await Self.request("stop", input: ["id": id], settings: config) } }
        sessionID = nil; activeSettings = nil; status = "点击等待后，再到官网发送验证码。"
    }
}

enum ClaudeMailLink {
    static func validated(_ value: String, email: String? = nil) -> URL? {
        guard value.count <= 2048, let url = URL(string: value), url.scheme == "https", url.host == "claude.ai",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.path == "/magic-link", url.query == nil, let fragment = url.fragment else { return nil }
        let parts = fragment.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]).range(of: "^[A-Za-z0-9_-]{16,512}$", options: .regularExpression) != nil,
              String(parts[1]).range(of: "^[A-Za-z0-9+/=_-]{4,512}$", options: .regularExpression) != nil else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8),
              let address = try? AccountPoolStore.email(decoded), email == nil || address == email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        return url
    }
}
