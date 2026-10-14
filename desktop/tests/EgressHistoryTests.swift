import Foundation

@main struct EgressHistoryTests {
    static func main() throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw EgressDiagnosticError.message(message) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("egress-history-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let time = Date(timeIntervalSince1970: 1_000_000)
        let host = "api.anthropic.com"
        let first = EgressProbeResult(kind: .terminal, ip: "198.51.100.1", country: "US")
        let second = EgressProbeResult(kind: .terminal, ip: "198.51.100.2", country: "US")
        var history = EgressIPHistory(fileURL: file, now: time)
        try require(history.record(first, host: host, now: time) == nil, "First IP must not be a change")
        try require(history.record(first, host: host, now: time.addingTimeInterval(1)) == nil && history.records.count == 1, "Duplicate IP not deduplicated")
        try require(history.record(second, host: host, now: time.addingTimeInterval(2)) == first.ip, "Previous IP missing on change")
        try require(history.record(first, host: host, now: time.addingTimeInterval(3)) == second.ip && history.records.count == 2, "Returning IP must detect change and stay deduplicated")
        let otherPath = EgressProbeResult(kind: .browser, ip: second.ip, country: "US")
        try require(history.record(otherPath, host: host, now: time.addingTimeInterval(4)) == nil, "Different paths must not be compared")
        try require(history.record(second, host: "claude.ai", now: time.addingTimeInterval(5)) == nil, "Different hosts must not be compared")
        let failed = EgressProbeResult(kind: .terminal, ip: "198.51.100.3", error: "timeout")
        try require(history.record(failed, host: host, now: time.addingTimeInterval(6)) == nil && history.records.count == 4, "Failed request overwritten history")
        var reloaded = EgressIPHistory(fileURL: file, now: time.addingTimeInterval(7))
        try require(reloaded.records.count == 4 && reloaded.uniqueIPs.count == 2, "History did not survive restart or global deduplication")
        try require(reloaded.record(second, host: host, now: time.addingTimeInterval(8)) == first.ip, "Restart lost preceding IP")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        try require(permissions?.intValue == 0o600, "History permissions must be user-only")
        reloaded.prune(now: time.addingTimeInterval(EgressIPHistory.lifetime + 8))
        try require(reloaded.records.count == 3 && reloaded.uniqueIPs == [second.ip!], "Old history must expire but latest IP of every path must survive")
        var daysLater = EgressIPHistory(fileURL: file, now: time.addingTimeInterval(7 * EgressIPHistory.lifetime))
        try require(daysLater.records.count == 3, "Latest IP disappeared after restart beyond 24 hours")
        try require(daysLater.record(first, host: host, now: time.addingTimeInterval(7 * EgressIPHistory.lifetime + 1)) == second.ip, "Latest IP must detect change even days later")
        try require(daysLater.record(first, host: host, now: time.addingTimeInterval(8 * EgressIPHistory.lifetime + 2)) == nil && daysLater.records.count == 3, "Repeated latest IP should stay deduplicated while old history expires")
        try require(EgressIPHistory.normalized("2001:0DB8:0:0:0:0:0:1") == EgressIPHistory.normalized("2001:db8::1"), "Equivalent IPv6 addresses differ")
        try require(EgressIPHistory.normalized("invalid") == nil, "Invalid IP accepted")
        try Data("corrupt".utf8).write(to: file)
        let corrupt = EgressIPHistory(fileURL: file, now: time)
        try require(corrupt.records.isEmpty && corrupt.warning != nil, "Corrupt cache did not degrade safely")
        let trace = "h=api.anthropic.com\nip=198.51.100.1\nloc=US\ncolo=LAX\n"
        try require(EgressLocalDiagnostics.parse(trace, host: host, kind: .terminal, milliseconds: 1).isSuccess, "Expected trace rejected")
        try require(!EgressLocalDiagnostics.parse(trace, host: "claude.ai", kind: .terminal, milliseconds: 1).isSuccess, "Trace for another host accepted")
        try require(!EgressLocalDiagnostics.parse(trace, host: host, kind: .terminal, milliseconds: 1, status: 403).isSuccess, "HTTP failure accepted")
        let target = URL(string: "https://api.anthropic.com/cdn-cgi/trace")!
        try require(EgressBrowserProbe.permits(target, target: target), "Whitelisted browser target rejected")
        try require(!EgressBrowserProbe.permits(URL(string: "https://api.anthropic.com/login")!, target: target), "Login redirect accepted")
        try require(!EgressBrowserProbe.permits(URL(string: "https://claude.ai/cdn-cgi/trace")!, target: target), "Other browser host accepted")
        let pipe = EgressLocalDiagnostics.run("/bin/cat", [], timeout: 2, input: "stdin fixture")
        try require(pipe.code == 0 && pipe.text == "stdin fixture", "Process stdin input not passed correctly")
        print("Verified trace host and HTTP status checks, browser redirect isolation, stdin secrets, deduplication, A→B→A changes, host/path isolation, failed probes, restart, IPv6 normalization, old-record expiry, permanent latest-IP retention and private persistence.")
    }
}
