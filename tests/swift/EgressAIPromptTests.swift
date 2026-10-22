import XCTest
@testable import SubscriptionStudio

final class EgressAIPromptTests: XCTestCase {
    @MainActor func testPromptSeparatesIPv6ControlFromBrowserAndDoesNotAssertStartupCause() {
        let model = EgressCheckModel(history: EgressIPHistory(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        // IPv6 is one leak check on the API host; the browser is checked on its own page, not here.
        model.results[EgressCheckModel.ipv6Host] = [.ipv6: .init(kind: .ipv6, ip: "2001:db8::1", country: "CN"), .terminal: .init(kind: .terminal, skippedReason: "未配置")]
        model.results["claude.ai"] = [.ipv4: .init(kind: .ipv4, ip: "203.0.113.5", country: "US")]
        let prompt = model.aiTroubleshootingPrompt
        XCTAssertTrue(prompt.contains("IPv6 绕过代理检测"))
        XCTAssertTrue(prompt.contains("已泄漏，地区 CN"))
        XCTAssertTrue(prompt.contains("浏览器出口与时区不在本检测范围"))
        XCTAssertTrue(prompt.contains("跳过，未验证，不计作失败"))
        XCTAssertTrue(prompt.contains("是否刚重启"))
        XCTAssertFalse(prompt.contains("203.0.113.5"))
        XCTAssertFalse(prompt.contains("2001:db8::1"))
    }
    @MainActor func testDistinctIPsWithSameMaskStayDistinctAndCredentialsAreNotExported() {
        let model = EgressCheckModel(history: EgressIPHistory(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        model.proxyEnabled = true
        model.proxy = "http://user:TOPSECRET@example.com:7890"
        model.results["claude.ai"] = [.ipv4: .init(kind: .ipv4, ip: "203.0.113.5", country: "US"), .terminal: .init(kind: .terminal, ip: "203.10.99.5", country: "US"), .proxy: .init(kind: .proxy, error: "HTTP 403 https://example.com/private?token=TOPSECRET")]
        let prompt = model.aiTroubleshootingPrompt
        XCTAssertTrue(prompt.contains("出口1"))
        XCTAssertTrue(prompt.contains("出口2"))
        XCTAssertTrue(prompt.contains("HTTP 403"))
        for privateValue in ["TOPSECRET", "user:", "example.com", "203.0.113.5", "203.10.99.5", "private?token"] { XCTAssertFalse(prompt.contains(privateValue)) }
        XCTAssertTrue(prompt.contains("取得我的同意"))
    }
}
