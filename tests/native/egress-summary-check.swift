import Foundation

@main struct EgressSummaryChecks {
    @MainActor static func main() {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = EgressCheckModel(history: EgressIPHistory(fileURL: temporary))
        for host in EgressLocalDiagnostics.hosts {
            for kind in model.enabledKinds {
                model.results[host, default: [:]][kind] = kind == .claude
                    ? EgressProbeResult(kind: kind, skippedReason: "未配置")
                    : EgressProbeResult(kind: kind, ip: "203.0.113.5", country: "US")
            }
        }
        precondition(model.successful.count == 12 && model.skippedCount == 3 && model.failedCount == 0)
        precondition(model.summary == "已检测的出口一致")
        model.results["claude.ai"]?[.browser] = EgressProbeResult(kind: .browser, error: "连接失败")
        precondition(model.failedCount == 1 && model.summary == "已取得出口，部分检测失败")
        model.results["claude.ai"]?[.browser] = EgressProbeResult(kind: .browser, ip: "203.0.113.6", country: "HK")
        precondition(model.summary == "检测到非美国出口")
        model.results["claude.ai"]?[.browser] = EgressProbeResult(kind: .browser, ip: "203.0.113.6", country: "US")
        precondition(model.summary == "检测到多个出口 IP")
        model.results = [:]
        precondition(model.summary == "准备检查网络出口")
        print("Egress summary: skipped, failed, mixed country, mixed IP and empty states passed")
    }
}
