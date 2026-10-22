import Foundation
import CryptoKit
import Yams

private final class SubscriptionHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var data = Data(); var response: HTTPURLResponse?
    let limit: Int
    var completion: ((Result<(Data, HTTPURLResponse), Error>) -> Void)?
    init(limit: Int) { self.limit = limit }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(response.expectedContentLength > Int64(limit) ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { if self.data.count + data.count > limit { dataTask.cancel() } else { self.data.append(data) } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate(); completion = nil }
        if error != nil { completion?(.failure(SubscriptionFailure("网络请求失败或响应过大，请检查网络后重试"))) }
        else if let response { completion?(.success((data, response))) }
        else { completion?(.failure(SubscriptionFailure("服务器未返回有效响应"))) }
    }
}
enum SubscriptionNetwork {
    static func request(_ request: URLRequest, limit: Int = 2 * 1024 * 1024) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        let delegate = SubscriptionHTTPDelegate(limit: limit)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            delegate.completion = { continuation.resume(with: $0) }; session.dataTask(with: request).resume()
        }
    }
    static func checkHost(_ host: String) async throws {
        let addresses: [String] = await Task.detached {
            var result: UnsafeMutablePointer<addrinfo>?
            var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
            defer { freeaddrinfo(first) }
            var values: [String] = [], current: UnsafeMutablePointer<addrinfo>? = first
            while let item = current {
                var output = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &output, socklen_t(output.count), nil, 0, NI_NUMERICHOST) == 0 { values.append(String(cString: output)) }
                current = item.pointee.ai_next
            }
            return values
        }.value
        guard !addresses.isEmpty, addresses.allSatisfy(SubscriptionCore.publicIP) else { throw SubscriptionFailure("域名无法解析为允许的公共地址") }
    }
    /// Some providers 403 unknown clients; a mainstream Clash client UA gets the config plus Subscription-Userinfo.
    static let userAgent = "clash-verge/v2.0.0"
    static func fetch(_ sourceURL: String) async throws -> SubscriptionSource {
        var url = try SubscriptionCore.publicURL(sourceURL)
        for _ in 0..<6 {
            try await checkHost((url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
            var request = URLRequest(url: url); request.setValue(SubscriptionNetwork.userAgent, forHTTPHeaderField: "User-Agent"); request.setValue("", forHTTPHeaderField: "Cookie"); request.setValue("", forHTTPHeaderField: "Authorization")
            let (data, response) = try await self.request(request)
            if (300...399).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL { url = try SubscriptionCore.publicURL(next.absoluteString); continue }
            guard response.statusCode == 200, let text = String(data: data, encoding: .utf8) else { throw SubscriptionFailure("源订阅返回 HTTP \(response.statusCode)，请检查访问权限或网络") }
            let config = try SubscriptionCore.parse(text)
            var name: String?
            if let header = response.value(forHTTPHeaderField: "Content-Disposition"), let expression = try? NSRegularExpression(pattern: "filename\\*=UTF-8''([^;]+)|filename=\"?([^\";]+)", options: .caseInsensitive), let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) {
                for i in 1..<match.numberOfRanges { if let range = Range(match.range(at: i), in: header) { name = String(header[range]).removingPercentEncoding; break } }
            }
            if name == nil, let title = response.value(forHTTPHeaderField: "Profile-Title") { name = title.hasPrefix("base64:") ? Data(base64Encoded: String(title.dropFirst(7))).flatMap { String(data: $0, encoding: .utf8) } : title }
            if name == nil && ["yaml", "yml"].contains(url.pathExtension) { name = url.deletingPathExtension().lastPathComponent }
            let info = response.value(forHTTPHeaderField: "Subscription-Userinfo")
            // Keep numeric fields only; some providers send an empty `expire=` for no expiry.
            let safeInfo = info.flatMap { raw -> String? in
                guard raw.count <= 256 else { return nil }
                let parts = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard parts.allSatisfy({ $0.range(of: "^(?:upload|download|total|expire)=[0-9]*$", options: .regularExpression) != nil }) else { return nil }
                let fields = parts.filter { !$0.hasSuffix("=") }
                return fields.isEmpty ? nil : fields.joined(separator: "; ")
            }
            return SubscriptionSource(config: config, fetchedAt: ISO8601DateFormatter().string(from: Date()), sourceName: name.map { String(SubscriptionCore.filename($0).dropLast(5)) }, userInfo: safeInfo)
        }
        throw SubscriptionFailure("源订阅重定向次数过多")
    }
    static let remoteOrigin = "https://node.tangchen02.top"
    static let legacyOrigin = "https://cc-assistant-api.tangchen19942016.workers.dev"
    static func remoteOrigin(_ remote: SubscriptionRemote) throws -> String {
        guard let url = URLComponents(string: remote.subscriptionUrl), url.scheme == "https", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.port == nil || url.port == 443, let host = url.host else { throw SubscriptionFailure("远程订阅地址无效") }
        let origin = "https://" + host
        guard [remoteOrigin, legacyOrigin].contains(origin), SubscriptionStorage.valid(remote.id, length: 32), SubscriptionStorage.valid(remote.manageKey, length: 64), SubscriptionStorage.valid(remote.downloadKey, length: 64), url.path.hasPrefix("/remote-sub/\(remote.id)/\(remote.downloadKey)/") else { throw SubscriptionFailure("远程订阅地址不属于配置的托管服务") }
        return origin
    }
    static func remoteRequest(origin: String, path: String, method: String, key: String?, body: Data?) async throws -> [String: Any] {
        guard [remoteOrigin, legacyOrigin].contains(origin), let url = URL(string: origin + path) else { throw SubscriptionFailure("远程服务地址无效") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        if let body, body.count > 1572864 { throw SubscriptionFailure("远程订阅内容超过 1.5 MiB 限制") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await self.request(request, limit: 65536)
        if method == "DELETE" && response.statusCode == 404 { return [:] }
        guard (200...299).contains(response.statusCode) else { throw SubscriptionFailure("远程服务返回 HTTP \(response.statusCode)") }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
