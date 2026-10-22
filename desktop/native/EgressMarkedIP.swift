import Foundation

struct EgressIPMarker: Codable, Equatable {
    let ip: String
    let markedAt: Date
}

@MainActor final class EgressMarkedIPStore {
    private struct State: Codable { var version = 1; var marker: EgressIPMarker? }
    static let defaultFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Subscription Studio/marked-ip.json")
    let fileURL: URL
    private(set) var marker: EgressIPMarker?
    private(set) var hasStoredState = false
    private(set) var warning: String?
    private var writable = true
    init(fileURL: URL) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        hasStoredState = true
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 4096 else { throw SubscriptionFailure("标记数据过大") }
            let state = try JSONDecoder().decode(State.self, from: data)
            guard state.version == 1 else { throw SubscriptionFailure("标记格式不支持") }
            if let value = state.marker {
                guard let ip = EgressIPHistory.normalized(value.ip) else { throw SubscriptionFailure("标记 IP 无效") }
                marker = .init(ip: ip, markedAt: value.markedAt)
            }
        } catch { writable = false; warning = "无法读取原标记，请保留数据文件后排查" }
    }
    static func legacyCandidate(fingerprints: Set<String>, knownIPs: [String]) -> String? {
        guard fingerprints.count == 1, let fingerprint = fingerprints.first else { return nil }
        let matches = Set(knownIPs.filter { EgressProbeResult(kind: .terminal, ip: $0).fingerprint == fingerprint }.compactMap(EgressIPHistory.normalized))
        return matches.count == 1 ? matches.first : nil
    }
    func mark(_ value: String, at date: Date = Date()) throws {
        guard let ip = EgressIPHistory.normalized(value) else { throw SubscriptionFailure("IP 地址无效") }
        try commit(.init(ip: ip, markedAt: date))
    }
    func clear() throws { try commit(nil) }
    private func commit(_ marker: EgressIPMarker?) throws {
        guard writable else { throw SubscriptionFailure(warning ?? "标记数据只读") }
        try SubscriptionStorage.privateWrite(JSONEncoder().encode(State(marker: marker)), to: fileURL)
        self.marker = marker; hasStoredState = true; warning = nil
    }
}
