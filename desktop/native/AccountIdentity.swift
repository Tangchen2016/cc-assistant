import Foundation

struct AccountIdentitySnapshot: Codable, Equatable, Sendable {
    var email: String
    var accountID: String?
    var name: String?
    var plan: String?
    var planIsInferred: Bool
    var remoteCreatedAt: Date?
    var checkedAt: Date
    var details: AccountBasicDetails? = nil
    var usage: AccountUsage? = nil
}

struct AccountBasicDetails: Codable, Equatable, Sendable {
    var displayName: String?
    var verified: Bool?
    var verificationCompletedAt: Date?
    var onboardingComplete: Bool?
    var remoteUpdatedAt: Date?
    var organizations: [AccountOrganizationDetails]
}
struct AccountOrganizationDetails: Codable, Equatable, Sendable {
    var id: String?
    var name: String?
    var role: String?
    var seatTier: String?
    var analyticsPlan: String?
    var planDisplayName: String?
    var planDisplayLabel: String?
    var rateLimitTier: String?
    var billingType: String?
    var billingIssue: String?
    var accessBlock: String?
    var subscriptionPause: String?
    var apiDisabledReason: String?
}

enum AccountConnectionError: LocalizedError, Equatable {
    case invalidSession, unauthorized, restricted, rateLimited, badResponse, network, redirect, mismatch, noConnection, changed
    case browser(String)
    var errorDescription: String? {
        switch self {
        case .invalidSession: return "请粘贴有效的 sessionKey 值，不要包含其他 Cookie 或换行。"
        case .unauthorized: return "会话已失效或尚未登录，请重新接入。"
        case .restricted: return "官网拒绝读取（403），可能需要在浏览器完成验证；不能据此判定账号被停用。"
        case .rateLimited: return "请求过于频繁，请稍后重试。"
        case .badResponse: return "官网未返回可识别的账号资料，未修改已有记录。"
        case .network: return "账号读取失败，请检查当前线路后重试。已有资料保留。"
        case .redirect: return "账号接口发生跳转，已停止请求，请在官方页面确认登录。"
        case .mismatch: return "识别到的账号与目标邮箱或原账号标识不一致，未覆盖记录。"
        case .noConnection: return "此账号尚未关联，请先接入登录或 Session。"
        case .changed: return "账号或关联已改变，已忽略旧的读取结果。"
        case .browser(let message): return message
        }
    }
}

enum AccountIdentityParser {
    static func sessionKey(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("sessionKey=") { value.removeFirst("sessionKey=".count) }
        guard (16...4096).contains(value.utf8.count),
              value.range(of: #"^[A-Za-z0-9._~-]+$"#, options: .regularExpression) != nil else { throw AccountConnectionError.invalidSession }
        return value
    }
    static func checkStatus(_ status: Int) throws {
        switch status {
        case 200: return
        case 401: throw AccountConnectionError.unauthorized
        case 403: throw AccountConnectionError.restricted
        case 429: throw AccountConnectionError.rateLimited
        case 300..<400: throw AccountConnectionError.redirect
        default: throw AccountConnectionError.badResponse
        }
    }
    private static func identifyPlan(_ account: [String: Any]) -> (name: String?, inferred: Bool) {
        let names = ["free": "Free", "pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise", "ultra": "Ultra"]
        func text(_ value: Any?) -> String? {
            guard let raw = value as? String else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value.isEmpty ? nil : value
        }
        func named(_ value: String?) -> String? {
            guard let value else { return nil }
            return names[value] ?? (value.hasPrefix("claude_") ? names[String(value.dropFirst(7))] : nil)
        }
        let memberships = account["memberships"] as? [[String: Any]] ?? []
        let organization = memberships.count == 1 ? memberships[0]["organization"] as? [String: Any] : nil
        let tier = text(organization?["rate_limit_tier"])
        let words = (tier ?? "").split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        func label(_ name: String) -> String {
            guard name == "Max", let index = words.firstIndex(of: "max"), words.indices.contains(index + 1),
                  ["5x", "20x"].contains(words[index + 1]) else { return name }
            return "Max " + words[index + 1]
        }
        // The web account response exposes the plan on its organization.
        if let explicit = text(organization?["analytics_subscription_plan"]) {
            return (named(explicit).map(label), false)
        }
        // Explicit plan fields outrank heuristic organization/tier hints.
        if let explicit = text(account["subscription_type"]) { return (named(explicit).map(label), false) }
        guard let organization else { return (nil, false) }
        if let explicit = text(organization["subscription_type"]) { return (named(explicit).map(label), false) }
        let capabilities = organization["capabilities"] as? [String] ?? []
        let type = text(organization["organization_type"])
        var hints = Set(capabilities.filter { $0.hasPrefix("claude_") }.compactMap { named($0) })
        if let name = named(type) { hints.insert(name) }
        if words.contains("claude") {
            for (key, name) in names where words.contains(key) { hints.insert(name) }
        }
        if hints.count == 1, let name = hints.first { return (label(name), true) }
        if hints.isEmpty, tier == "default_claude_ai", Set(capabilities) == ["chat"],
           organization["billing_type"] is NSNull, type == nil,
           account["has_claude_pro"] as? Bool != true, account["has_claude_max"] as? Bool != true {
            return ("Free", true)
        }
        return (nil, false)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> AccountIdentitySnapshot {
        guard data.count <= 262144,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEmail = object["email_address"] as? String,
              let email = try? AccountPoolStore.email(rawEmail) else { throw AccountConnectionError.badResponse }
        func safeText(_ value: Any?, max: Int) -> String? {
            guard let string = value as? String else { return nil }
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text.count <= max && text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) ? text : nil
        }
        let identifiedPlan = identifyPlan(object)
        let plan = identifiedPlan.name, inferred = identifiedPlan.inferred
        func date(_ value: Any?) -> Date? {
            guard let raw = safeText(value, max: 80) else { return nil }
            let formatter = ISO8601DateFormatter()
            if let value = formatter.date(from: raw) { return value }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: raw)
        }
        func flag(_ value: Any?) -> Bool? {
            guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return nil }
            return try? JSONDecoder().decode(Bool.self, from: data)
        }
        func signal(_ object: [String: Any], _ key: String) -> String? {
            guard let value = object[key] else { return nil }
            if value is NSNull { return "官网未报告" }
            if let value = flag(value) { return value ? "官网返回 true，请核对" : "官网返回 false" }
            if let text = safeText(value, max: 200) { return text }
            return "官网返回结构化信息，需进一步核对"
        }
        let organizations = ((object["memberships"] as? [[String: Any]]) ?? []).prefix(50).compactMap { membership -> AccountOrganizationDetails? in
            guard let org = membership["organization"] as? [String: Any] else { return nil }
            return .init(id: safeText(org["uuid"], max: 128), name: safeText(org["name"], max: 200),
                         role: safeText(membership["role"], max: 100), seatTier: safeText(membership["seat_tier"], max: 100),
                         analyticsPlan: safeText(org["analytics_subscription_plan"], max: 100),
                         planDisplayName: safeText(org["plan_display_name"], max: 100), planDisplayLabel: safeText(org["plan_display_label"], max: 100),
                         rateLimitTier: safeText(org["rate_limit_tier"], max: 160), billingType: safeText(org["billing_type"], max: 100),
                         billingIssue: signal(org, "billing_issue"), accessBlock: signal(org, "access_block"), subscriptionPause: signal(org, "subscription_pause"),
                         apiDisabledReason: signal(org, "api_disabled_reason"))
        }
        let details = AccountBasicDetails(displayName: safeText(object["display_name"], max: 100), verified: flag(object["is_verified"]),
                                          verificationCompletedAt: date(object["completed_verification_at"]), onboardingComplete: flag(object["onboarding_complete"]),
                                          remoteUpdatedAt: date(object["updated_at"]), organizations: organizations)
        return .init(email: email, accountID: safeText(object["uuid"], max: 128), name: safeText(object["full_name"], max: 100),
                     plan: plan, planIsInferred: inferred, remoteCreatedAt: date(object["created_at"]), checkedAt: now, details: details)
    }
}

struct AccountSessionReading: Sendable {
    let identity: AccountIdentitySnapshot
    let sessionKey: String
}

final class AccountRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum AccountSessionClient {
    static let endpoint = URL(string: "https://claude.ai/api/account")!
    static func request(_ value: String) throws -> URLRequest {
        let key = try AccountIdentityParser.sessionKey(value)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    static func proxyDictionary(_ value: String?) throws -> [AnyHashable: Any]? {
        guard let value, !value.isEmpty else { return nil }
        guard let url = URL(string: value), let host = url.host, let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, ["", "/"].contains(url.path) else {
            throw AccountConnectionError.browser("代理设置无效，请先检查浏览器菜单中的代理。")
        }
        switch url.scheme?.lowercased() {
        case "http": return ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port, "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        case "socks5": return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port]
        default: throw AccountConnectionError.browser("Session 读取支持 HTTP / SOCKS5 代理；当前代理请改用浏览器读取，不会自动直连。")
        }
    }
    static func read(_ value: String, proxy: String? = nil, configuration: URLSessionConfiguration = .ephemeral) async throws -> AccountSessionReading {
        try Task.checkCancellation()
        let key = try AccountIdentityParser.sessionKey(value), request = try request(key)
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        configuration.connectionProxyDictionary = try proxyDictionary(proxy)
        let session = URLSession(configuration: configuration, delegate: AccountRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.url == endpoint else { throw AccountConnectionError.badResponse }
            try AccountIdentityParser.checkStatus(response.statusCode)
            var data = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard data.count < 262144 else { throw AccountConnectionError.badResponse }
                data.append(byte)
            }
            var identity = try AccountIdentityParser.parse(data)
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                if let name = entry.key as? String, let value = entry.value as? String { result[name] = value }
            }
            let renewed = HTTPCookie.cookies(withResponseHeaderFields: headers, for: endpoint)
                .first { $0.name == "sessionKey" && ["claude.ai", ".claude.ai"].contains($0.domain) && $0.isSecure }
                .flatMap { try? AccountIdentityParser.sessionKey($0.value) }
            if let org = AccountUsageParser.organizationID(data) {
                identity.usage = await AccountUsageParser.read(session: session, cookie: "sessionKey=\(renewed ?? key)", organization: org)
            }
            return .init(identity: identity, sessionKey: renewed ?? key)
        } catch is CancellationError { throw CancellationError() }
        catch let error as AccountConnectionError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw AccountConnectionError.network }
    }
}
