import Foundation

enum BrowserAccountReader {
    static func socketURL(_ portFile: String) throws -> URL {
        let lines = portFile.split(separator: "\n").map(String.init)
        guard portFile.utf8.count <= 1024, lines.count == 2, let port = Int(lines[0]), (1...65535).contains(port),
              lines[1].range(of: #"^/devtools/browser/[A-Za-z0-9-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "ws://127.0.0.1:\(port)\(lines[1])") else {
            throw AccountConnectionError.browser("浏览器连接尚未就绪，请稍后重试。")
        }
        return url
    }
    static func isClaudePage(_ info: [String: Any]) -> Bool {
        guard info["type"] as? String == "page", let value = info["url"] as? String, let url = URL(string: value) else { return false }
        return url.scheme == "https" && url.host == "claude.ai" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    static func read(profile: URL) async throws -> AccountIdentitySnapshot {
        try Task.checkCancellation()
        let file = profile.appendingPathComponent("DevToolsActivePort")
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            throw AccountConnectionError.browser("请从接入流程打开独立浏览器；如已打开，请先关闭该独立浏览器再重新打开。")
        }
        let data = try handle.read(upToCount: 1025) ?? Data(); try? handle.close()
        guard let text = String(data: data, encoding: .utf8) else { throw AccountConnectionError.badResponse }
        let url = try socketURL(text)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url); socket.maximumMessageSize = 1_048_576; socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        do {
            return try await withThrowingTaskGroup(of: AccountIdentitySnapshot.self) { group in
                group.addTask {
                    let rpc = BrowserAccountRPC(socket: socket)
                    let targets = try await rpc.call("Target.getTargets")
                    guard let infos = targets["targetInfos"] as? [[String: Any]], let target = infos.first(where: isClaudePage),
                          let targetID = target["targetId"] as? String else {
                        throw AccountConnectionError.browser("请先在此独立浏览器打开 claude.ai，并完成注册或登录。")
                    }
                    let attached = try await rpc.call("Target.attachToTarget", params: ["targetId": targetID, "flatten": true])
                    guard let sessionID = attached["sessionId"] as? String else { throw AccountConnectionError.badResponse }
                    // Only account metadata crosses this connection. No cookie export or browser credential scan.
                    let expression = """
                    (async () => {
                      if (location.origin !== 'https://claude.ai') throw new Error('origin');
                      const r = await fetch('https://claude.ai/api/account', {method:'GET',credentials:'include',mode:'same-origin',redirect:'error',cache:'no-store'});
                      const body = await r.text();
                      if (body.length > 262144) throw new Error('size');
                      return JSON.stringify({status:r.status,body});
                    })()
                    """
                    let result = try await rpc.call("Runtime.evaluate", params: ["expression": expression, "awaitPromise": true, "returnByValue": true, "timeout": 15000], sessionID: sessionID)
                    guard result["exceptionDetails"] == nil, let remote = result["result"] as? [String: Any],
                          let payload = remote["value"] as? String, payload.utf8.count <= 524288,
                          let envelope = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                          let status = envelope["status"] as? Int, let body = envelope["body"] as? String else { throw AccountConnectionError.badResponse }
                    try AccountIdentityParser.checkStatus(status)
                    var identity = try AccountIdentityParser.parse(Data(body.utf8))
                    if let org = AccountUsageParser.organizationID(Data(body.utf8)) {
                        identity.usage = await usage(rpc: rpc, sessionID: sessionID, organization: org)
                    }
                    return identity
                }
                group.addTask { try await Task.sleep(nanoseconds: 20_000_000_000); throw AccountConnectionError.network }
                defer { group.cancelAll(); socket.cancel(with: .goingAway, reason: nil) }
                guard let value = try await group.next() else { throw AccountConnectionError.network }
                return value
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as AccountConnectionError { throw error }
        catch { throw AccountConnectionError.network }
    }
    /// Same-origin fetch inside the page; org is a validated UUID so interpolation is safe.
    private static func usage(rpc: BrowserAccountRPC, sessionID: String, organization: String) async -> AccountUsage? {
        let expression = """
        (async () => {
          const r = await fetch('\(AccountUsageParser.url(organization).absoluteString)', {method:'GET',credentials:'include',mode:'same-origin',redirect:'error',cache:'no-store'});
          if (r.status !== 200) return '';
          const body = await r.text();
          return body.length > 65536 ? '' : body;
        })()
        """
        guard let result = try? await rpc.call("Runtime.evaluate", params: ["expression": expression, "awaitPromise": true, "returnByValue": true, "timeout": 15000], sessionID: sessionID),
              result["exceptionDetails"] == nil, let body = (result["result"] as? [String: Any])?["value"] as? String else { return nil }
        return AccountUsageParser.parse(Data(body.utf8))
    }
}

private final class BrowserAccountRPC: @unchecked Sendable {
    let socket: URLSessionWebSocketTask
    private var nextID = 0
    init(socket: URLSessionWebSocketTask) { self.socket = socket }
    func call(_ method: String, params: [String: Any] = [:], sessionID: String? = nil) async throws -> [String: Any] {
        nextID += 1; let id = nextID
        var request: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionID { request["sessionId"] = sessionID }
        let data = try JSONSerialization.data(withJSONObject: request)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        return try await withTaskCancellationHandler {
            for _ in 0..<128 {
                try Task.checkCancellation()
                let message = try await socket.receive(), data: Data
                switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw AccountConnectionError.badResponse }
                guard data.count <= 1_048_576, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AccountConnectionError.badResponse }
                if object["id"] as? Int == id {
                    guard object["error"] == nil, let result = object["result"] as? [String: Any] else { throw AccountConnectionError.badResponse }
                    return result
                }
            }
            throw AccountConnectionError.badResponse
        } onCancel: { [socket] in socket.cancel(with: .goingAway, reason: nil) }
    }
}
