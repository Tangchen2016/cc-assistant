import Foundation

struct BrowserExitTimeZone: Equatable, Sendable {
    let ip: String
    let identifier: String
    let location: String
    var display: String {
        let offset = TimeZone(identifier: identifier).map { TimeZoneDiagnostics.system(zone: $0).offsetText } ?? ""
        return "\(identifier) · \(offset)"
    }
}

enum BrowserExitTimeZoneLookup {
    private struct Response: Decodable {
        let success: Bool
        let ip: String?
        let country: String?
        let region: String?
        let city: String?
        let timezone: Zone?
        struct Zone: Decodable { let id: String? }
    }
    static func parse(_ data: Data, expectedIP: String) throws -> BrowserExitTimeZone {
        guard data.count <= 32768, let expected = EgressIPHistory.normalized(expectedIP),
              let response = try? JSONDecoder().decode(Response.self, from: data), response.success,
              let ip = response.ip.flatMap(EgressIPHistory.normalized), ip == expected,
              let identifier = response.timezone?.id,
              identifier == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(identifier) else {
            throw SubscriptionFailure("未取得与出口 IP 匹配的有效时区，请稍后刷新或手动选择。")
        }
        var locations: [String] = []
        for field in [response.country, response.region, response.city] {
            if let field, !field.isEmpty, field.count <= 100,
               field.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), !locations.contains(field) { locations.append(field) }
        }
        return .init(ip: ip, identifier: identifier, location: locations.joined(separator: " · "))
    }
    static func resolve(configuration: PureBrowserConfiguration) async throws -> BrowserExitTimeZone {
        let result = await Task.detached(priority: .utility) { PureBrowserProbe.check(host: "claude.ai", configuration: configuration) }.value
        try Task.checkCancellation()
        guard result.isSuccess, let ip = result.ip.flatMap(EgressIPHistory.normalized) else {
            throw SubscriptionFailure("未能读取浏览器访问 Claude 的出口，请检查代理后刷新。")
        }
        var components = URLComponents(string: "https://ipwho.is/\(ip)")!
        components.queryItems = [.init(name: "fields", value: "success,ip,country,region,city,timezone.id")]
        var request = URLRequest(url: components.url!); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await SubscriptionNetwork.request(request, limit: 32768)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw SubscriptionFailure("出口时区查询暂不可用，请稍后刷新或手动选择。") }
        return try parse(data, expectedIP: ip)
    }
}
