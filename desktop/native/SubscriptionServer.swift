import Foundation
import Network

@MainActor final class SubscriptionServer: ObservableObject {
    @Published var status = "本机订阅服务尚未启动"
    @Published var ready = false
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    var localPage: ((String) -> (body: String, contentType: String, headers: [String: String])?)?
    var download: ((String, String) async throws -> (String, String, String?))?
    /// Clash override script for (node id, key); Clash Party re-fetches it when the override is refreshed.
    var overrideScript: ((String, String) throws -> String)?
    func overrideURL(id: String, key: String, name: String) -> String { "http://127.0.0.1:\(port)/override/\(id)/\(key)/\(SubscriptionCore.encoded(name)).js" }
    private(set) var port: UInt16
    init(port: UInt16 = 19473) { self.port = port }
    func start() {
        listener?.cancel(); ready = false
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener; status = "正在启动本机订阅服务…"
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: self.port = listener.port?.rawValue ?? self.port; self.ready = true; self.status = "本机订阅服务运行中 · \(self.port)"
                    case .failed(let error): self.ready = false; self.status = "本机订阅服务无法启动（\(error)）。请检查端口后重试；其他功能仍可使用。"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            listener.start(queue: .main)
        } catch { status = "无法创建本机订阅服务，请重试；环境检测和设置仍可使用。" }
    }
    func stop() { listener?.cancel(); listener = nil; ready = false; for connection in connections.values { connection.cancel() }; connections.removeAll(); for timer in timers.values { timer.cancel() }; timers.removeAll() }
    private func finish(_ id: UUID) { connections.removeValue(forKey: id)?.cancel(); timers.removeValue(forKey: id)?.cancel() }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        timers[id] = Task { [weak self] in try? await Task.sleep(nanoseconds: 30_000_000_000); guard !Task.isCancelled else { return }; self?.finish(id) }
        connection.start(queue: .main); receive(id, buffer: Data())
    }
    private func receive(_ id: UUID, buffer: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var accumulated = buffer; if let data { accumulated.append(data) }
                guard accumulated.count <= 8192 else { self.respond(id, status: 413, body: "Request too large"); return }
                if let text = String(data: accumulated, encoding: .utf8), text.contains("\r\n\r\n") { await self.handle(id, header: text); return }
                if complete || error != nil { self.finish(id) } else { self.receive(id, buffer: accumulated) }
            }
        }
    }
    private func handle(_ id: UUID, header: String) async {
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        guard first.count == 3, ["GET", "HEAD"].contains(first[0]) else { respond(id, status: 405, body: "Read only"); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() { let parts = line.split(separator: ":", maxSplits: 1); if parts.count == 2 { headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) } }
        let acceptedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard acceptedHosts.contains(headers["host"] ?? ""), headers["origin"].map({ acceptedHosts.map { "http://" + $0 }.contains($0) }) ?? true, !["cross-site", "same-site"].contains(headers["sec-fetch-site"] ?? "") else { respond(id, status: 403, body: "Local clients only"); return }
        if let page = localPage?(first[1]) {
            respond(id, status: 200, body: first[0] == "HEAD" ? "" : page.body, contentType: page.contentType, extra: page.headers)
            return
        }
        let parts = first[1].split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == "override", let overrideScript {
            do { respond(id, status: 200, body: first[0] == "HEAD" ? "" : try overrideScript(parts[1], parts[2]), contentType: "application/javascript; charset=utf-8") }
            catch { respond(id, status: 404, body: "Not found") }
            return
        }
        if first[1] == "/api/health" { respond(id, status: 200, body: "{\"status\":\"ok\"}", contentType: "application/json"); return }
        let path = first[1].split(separator: "/").map(String.init)
        guard !first[1].contains("?"), (3...4).contains(path.count), path[0] == "sub", SubscriptionStorage.valid(path[1], length: 32), SubscriptionStorage.valid(path[2], length: 64), let download else { respond(id, status: 404, body: "Not found"); return }
        do {
            let (yaml, name, info) = try await download(path[1], path[2])
            var extra = ["Profile-Title": "base64:" + Data(name.utf8).base64EncodedString(), "Content-Disposition": "attachment; filename=\"enhanced.yaml\"; filename*=UTF-8''\(SubscriptionCore.encoded(SubscriptionCore.filename(name)))"]
            if let info { extra["Subscription-Userinfo"] = info }
            respond(id, status: 200, body: first[0] == "HEAD" ? "" : yaml, contentType: "application/yaml; charset=utf-8", extra: extra)
        } catch { respond(id, status: 502, body: "Subscription unavailable. Check cc助手.") }
    }
    private func respond(_ id: UUID, status: Int, body: String, contentType: String = "text/plain; charset=utf-8", extra: [String: String] = [:]) {
        guard let connection = connections[id] else { return }
        let bytes = Data(body.utf8)
        let headers = ["Content-Type": contentType, "Content-Length": String(bytes.count), "Connection": "close", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"].merging(extra) { _, new in new }
        var response = Data(("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n" + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8); response.append(bytes)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.finish(id) } })
    }
}
