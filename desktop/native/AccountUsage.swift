import Foundation

/// claude.ai rolling limits: 5-hour session window and 7-day weekly window.
struct AccountUsage: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        var percent: Double  // 0–100 as reported by the web usage endpoint
        var resetsAt: Date?
    }
    var fiveHour: Window?
    var sevenDay: Window?
    /// Model-scoped weekly limits keyed by display name ("Opus", "Sonnet", "Fable"); absent models are omitted by the server.
    var models: [String: Window]? = nil
    var checkedAt: Date
    var highest: Double { ([fiveHour, sevenDay] + (models ?? [:]).values.map(Optional.some)).compactMap { $0?.percent }.max() ?? 0 }
    var sortedModels: [(name: String, window: Window)] { (models ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
}

enum AccountUsageParser {
    /// The organization whose limits matter: the one that can chat, else the only one.
    static func organizationID(_ accountData: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: accountData) as? [String: Any] else { return nil }
        let orgs = ((object["memberships"] as? [[String: Any]]) ?? []).compactMap { $0["organization"] as? [String: Any] }
        let org = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") == true } ?? (orgs.count == 1 ? orgs[0] : nil)
        guard let id = org?["uuid"] as? String,
              id.range(of: #"^[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil else { return nil }
        return id.lowercased()
    }
    static func url(_ organization: String) -> URL { URL(string: "https://claude.ai/api/organizations/\(organization)/usage")! }
    static func parse(_ data: Data, now: Date = Date()) -> AccountUsage? {
        guard data.count <= 65536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func window(_ key: String) -> AccountUsage.Window? {
            guard let raw = object[key] as? [String: Any], let value = (raw["utilization"] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            let reset = (raw["resets_at"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            return .init(percent: min(max(value, 0), 100), resetsAt: reset)
        }
        func date(_ value: Any?) -> Date? { (value as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }
        var models: [String: AccountUsage.Window] = [:]
        // Legacy top-level keys first; the newer limits[] list overrides the same model.
        for (key, name) in ["seven_day_opus": "Opus", "seven_day_sonnet": "Sonnet", "seven_day_fable": "Fable"] { models[name] = window(key) }
        for limit in (object["limits"] as? [[String: Any]] ?? []).prefix(50) {
            guard limit["kind"] as? String == "weekly_scoped", limit["group"] as? String == "weekly",
                  // Surface-specific sub-limits are not the model's weekly limit.
                  ((limit["scope"] as? [String: Any])?["surface"]).map({ $0 is NSNull }) ?? true,
                  let raw = (((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let name = ["fable": "Fable", "opus": "Opus", "sonnet": "Sonnet"][raw.lowercased()],
                  let value = (limit["percent"] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { continue }
            models[name] = .init(percent: min(value, 100), resetsAt: date(limit["resets_at"]))
        }
        let usage = AccountUsage(fiveHour: window("five_hour"), sevenDay: window("seven_day"), models: models.isEmpty ? nil : models, checkedAt: now)
        return usage.fiveHour == nil && usage.sevenDay == nil && models.isEmpty ? nil : usage
    }
    /// Best effort: a usage failure never fails the account read.
    static func read(session: URLSession, cookie: String, organization: String) async -> AccountUsage? {
        var request = URLRequest(url: url(organization), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(cookie, forHTTPHeaderField: "Cookie"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}
