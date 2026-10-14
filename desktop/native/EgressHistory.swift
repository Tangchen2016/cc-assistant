import Foundation
import Darwin

struct EgressIPObservation: Codable {
    let host: String
    let kind: EgressProbeKind
    let ip: String
    var country: String
    var lastSeen: Date
}

struct EgressIPHistory {
    private(set) var records: [EgressIPObservation] = []
    private(set) var warning: String?
    let fileURL: URL
    static let defaultFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Subscription Studio/ip-history.json")
    static let legacyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AnthropicEgressCheck/ip-history.json")
    static let lifetime: TimeInterval = 24 * 60 * 60

    init(fileURL: URL = Self.defaultFile, now: Date = Date()) {
        self.fileURL = fileURL
        if fileURL == Self.defaultFile && !FileManager.default.fileExists(atPath: fileURL.path),
           FileManager.default.fileExists(atPath: Self.legacyFile.path) {
            do {
                let data = try Data(contentsOf: Self.legacyFile)
                guard data.count < 2_000_000 else { throw EgressDiagnosticError.message("原 IP 历史文件过大") }
                _ = try JSONDecoder().decode([EgressIPObservation].self, from: data)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch { warning = "原 IP 历史无法迁移；本次检测仍可继续" }
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                guard data.count < 2_000_000 else { throw EgressDiagnosticError.message("IP 历史文件过大") }
                records = try JSONDecoder().decode([EgressIPObservation].self, from: data)
            } catch { warning = "无法读取 IP 历史；本次检测仍可继续" }
        }
        prune(now: now)
    }

    static func normalized(_ value: String) -> String? {
        var v4 = in_addr(); var v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            _ = withUnsafePointer(to: &v4) { inet_ntop(AF_INET, $0, &buffer, socklen_t(buffer.count)) }
        } else if value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            _ = withUnsafePointer(to: &v6) { inet_ntop(AF_INET6, $0, &buffer, socklen_t(buffer.count)) }
        } else { return nil }
        return String(cString: buffer)
    }

    mutating func prune(now: Date = Date()) {
        let previous = records
        records = []
        for var record in previous.sorted(by: { $0.lastSeen < $1.lastSeen }) {
            guard record.lastSeen <= now,
                  EgressLocalDiagnostics.hosts.contains(record.host), let ip = Self.normalized(record.ip) else { continue }
            record = EgressIPObservation(host: record.host, kind: record.kind, ip: ip, country: record.country, lastSeen: record.lastSeen)
            records.removeAll { $0.host == record.host && $0.kind == record.kind && $0.ip == record.ip }
            records.append(record)
        }
        records = records.filter { $0.lastSeen > now.addingTimeInterval(-Self.lifetime) || isLatest($0) }
        if records.count != previous.count { persist() }
    }

    func isLatest(_ record: EgressIPObservation) -> Bool {
        records.filter { $0.host == record.host && $0.kind == record.kind }
            .max(by: { $0.lastSeen < $1.lastSeen })?.ip == record.ip
    }
    func isLatestIP(_ ip: String) -> Bool { records.contains { $0.ip == ip && isLatest($0) } }

    // Returns the preceding successful IP only when this domain/path changes.
    mutating func record(_ result: EgressProbeResult, host: String, now: Date = Date()) -> String? {
        prune(now: now)
        guard result.isSuccess, EgressLocalDiagnostics.hosts.contains(host), let value = result.ip,
              let ip = Self.normalized(value) else { return nil }
        let previous = records.filter { $0.host == host && $0.kind == result.kind }.max(by: { $0.lastSeen < $1.lastSeen })?.ip
        records.removeAll { $0.host == host && $0.kind == result.kind && $0.ip == ip }
        records.append(EgressIPObservation(host: host, kind: result.kind, ip: ip, country: result.country ?? "未知", lastSeen: now))
        persist()
        return previous.flatMap { $0 == ip ? nil : $0 }
    }

    var uniqueIPs: [String] {
        Dictionary(grouping: records, by: \.ip).keys.sorted {
            lastSeen($0) > lastSeen($1)
        }
    }
    func lastSeen(_ ip: String) -> Date { records.filter { $0.ip == ip }.map(\.lastSeen).max() ?? .distantPast }
    func sources(_ ip: String) -> String {
        EgressLocalDiagnostics.hosts.compactMap { host in
            let kinds = EgressProbeKind.allCases.filter { kind in records.contains { $0.ip == ip && $0.host == host && $0.kind == kind } }
            return kinds.isEmpty ? nil : "\(host)：\(kinds.map(\.title).joined(separator: "、"))"
        }.joined(separator: "\n")
    }
    mutating private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            warning = nil
        } catch { warning = "IP 历史保存失败；记录暂时仅保留在内存中" }
    }
}

