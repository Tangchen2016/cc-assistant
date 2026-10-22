import XCTest
@testable import SubscriptionStudio

final class MailAssistantTests: XCTestCase {
    func testMailEndpointRequiresHTTPSAndRejectsCredentialsAndQuery() throws {
        let token = String(repeating: "a", count: 40)
        let valid = MailAssistantSettings(endpoint: "https://mail.example.com", token: token)
        XCTAssertEqual(try valid.validatedURL("watch").absoluteString, "https://mail.example.com/watch")
        for endpoint in ["http://mail.example.com", "https://user:password@mail.example.com", "https://mail.example.com/?token=x", "https://mail.example.com/#x"] {
            XCTAssertThrowsError(try MailAssistantSettings(endpoint: endpoint, token: token).validatedURL("watch"))
        }
        XCTAssertThrowsError(try MailAssistantSettings(endpoint: valid.endpoint, token: "short").validatedURL("watch"))
        XCTAssertThrowsError(try MailAssistantSettings(endpoint: valid.endpoint, token: token + "\r\nX-Test: x").validatedURL("watch"))
    }
    func testWaitingAndManualResponsesDecodeWithoutInventingCodes() throws {
        let waiting = try JSONDecoder().decode(MailAssistantReply.self, from: Data(#"{"waiting":true}"#.utf8))
        XCTAssertNil(waiting.code)
        let manual = try JSONDecoder().decode(MailAssistantReply.self, from: Data(#"{"manual":true,"email":"test@example.com","code":null}"#.utf8))
        XCTAssertEqual(manual.manual, true); XCTAssertNil(manual.code)
    }
    func testOfficialLoginLinkMustMatchRecipient() {
        let address = "sky@example.com"
        let link = "https://claude.ai/magic-link#" + String(repeating: "a", count: 32) + ":" + Data(address.utf8).base64EncodedString()
        XCTAssertNotNil(ClaudeMailLink.validated(link, email: address))
        XCTAssertNil(ClaudeMailLink.validated(link, email: "other@example.com"))
        for invalid in [link.replacingOccurrences(of: "claude.ai", with: "claude.ai.evil.com"), link.replacingOccurrences(of: "https:", with: "http:"), link.replacingOccurrences(of: "magic-link#", with: "magic-link?redirect=evil#"), link.replacingOccurrences(of: "claude.ai", with: "user@claude.ai")] {
            XCTAssertNil(ClaudeMailLink.validated(invalid, email: address))
        }
    }
}
