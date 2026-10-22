import Foundation
import SwiftUI
import Darwin

struct MobileTraceFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct MobileProbe: Identifiable, Equatable, Sendable {
    let host: String
    var ip: String?
    var country: String?
    var error: String?
    var elapsed: Int?
    var id: String { host }
    var finished: Bool { ip != nil || error != nil }
}

enum MobileTrace {
    static let hosts = ["api.anthropic.com", "claude.ai", "claude.com", "platform.claude.com"]
    static func normalizedIP(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var v4 = in_addr(), v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, value, &v4) == 1 { guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return nil } }
        else if inet_pton(AF_INET6, value, &v6) == 1 { guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil } }
        else { return nil }
        return String(cString: buffer)
    }
    static func parse(_ text: String, host: String) throws -> MobileProbe {
        guard hosts.contains(host), text.utf8.count <= 8192 else { throw MobileTraceFailure("检测文本超出支持范围。") }
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0]), value = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if ["h", "ip", "loc"].contains(key) {
                guard fields[key] == nil else { throw MobileTraceFailure("检测响应包含重复字段。") }
                fields[key] = value
            }
        }
        guard fields["h"] == host, let ip = fields["ip"].flatMap(normalizedIP),
              let country = fields["loc"], country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else {
            throw MobileTraceFailure("未读取到该域名的有效出口。")
        }
        return .init(host: host, ip: ip, country: country)
    }
    static func fetch(_ host: String) async -> MobileProbe {
        guard hosts.contains(host), let url = URL(string: "https://\(host)/cdn-cgi/trace?cc-check=\(UUID().uuidString)") else { return .init(host: host, error: "检测目标不受支持") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 16
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let start = Date()
        do {
            let (stream, response) = try await session.bytes(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw MobileTraceFailure("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)，未验证出口") }
            var data = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard data.count < 8192 else { throw MobileTraceFailure("响应超过大小限制") }
                data.append(byte)
            }
            guard let text = String(data: data, encoding: .utf8) else { throw MobileTraceFailure("响应不是有效文本") }
            var result = try parse(text, host: host); result.elapsed = Int(Date().timeIntervalSince(start) * 1000); return result
        } catch {
            return .init(host: host, error: (error as? MobileTraceFailure)?.message ?? ((error as? URLError)?.code == .timedOut ? "请求超时，未验证出口" : "请求失败，未验证出口"))
        }
    }
}

@MainActor final class MobileEgressModel: ObservableObject {
    @Published private(set) var results = MobileTrace.hosts.map { MobileProbe(host: $0) }
    @Published private(set) var running = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var marker: String?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; marker = defaults.string(forKey: "mobileMarkedIP").flatMap(MobileTrace.normalizedIP)
    }
    var finishedCount: Int { results.filter(\.finished).count }
    var addresses: [String] { Array(Set(results.compactMap(\.ip))).sorted() }
    var isConsistent: Bool { results.allSatisfy { $0.ip != nil } && addresses.count == 1 && (marker == nil || addresses.first == marker) }
    func mark(_ ip: String?) {
        guard let ip else { defaults.removeObject(forKey: "mobileMarkedIP"); marker = nil; return }
        guard let value = MobileTrace.normalizedIP(ip) else { return }
        defaults.set(value, forKey: "mobileMarkedIP"); marker = value
    }
    func start() {
        guard !running else { return }
        running = true; checkedAt = nil; results = MobileTrace.hosts.map { MobileProbe(host: $0) }
        task = Task { [weak self] in
            await withTaskGroup(of: MobileProbe.self) { group in
                for host in MobileTrace.hosts { group.addTask { await MobileTrace.fetch(host) } }
                for await result in group {
                    if let index = self?.results.firstIndex(where: { $0.host == result.host }) { self?.results[index] = result }
                }
            }
            self?.running = false; self?.checkedAt = Date()
        }
    }
}
