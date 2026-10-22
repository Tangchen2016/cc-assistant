import XCTest
@testable import SubscriptionStudio

final class TrafficLogTests: XCTestCase {
    func testExtractsRequestFromRealMihomoLine() {
        let line = #"time="2026-10-21T17:08:57.356538000+08:00" level=info msg="[TCP] 127.0.0.1:53827 --> claude.ai:443 match Match using cc-gate[REJECT]""#
        XCTAssertEqual(TrafficLog.message(fromEngineLine: line), "[TCP] 127.0.0.1:53827 --> claude.ai:443 match Match using cc-gate[REJECT]")
        XCTAssertNil(TrafficLog.message(fromEngineLine: ""))
    }

    func testSplitterReassemblesChunkedLines() {
        var lines: [String] = []
        let splitter = LineSplitter { lines.append($0) }
        splitter.feed(Data("first\nsec".utf8))
        splitter.feed(Data("ond\n".utf8))
        XCTAssertEqual(lines, ["first", "second"])
    }

    func testClosedConnectionsKeptThirtyMinutesAndCapped() {
        func row(_ id: String) -> LineEngine.Connection { .init(id: id, host: "claude.ai:443", destination: "", chain: "", rule: "", upload: 0, download: 0, start: nil) }
        let now = Date()
        var history = LineEngine.retainClosed([], adding: [row("old")], now: now.addingTimeInterval(-1801))
        history = LineEngine.retainClosed(history, adding: [row("new")], now: now)
        XCTAssertEqual(history.map(\.id), ["new"])  // older than 30 minutes dropped
        XCTAssertNotNil(history.first?.closedAt)
        XCTAssertEqual(LineEngine.retainClosed([], adding: (0..<600).map { row("\($0)") }, now: now).count, 500)
    }

    func testParsesRealConnectionPayload() {
        // Shape captured from the bundled mihomo /connections endpoint.
        let root: [String: Any] = ["connections": [[
            "id": "8d3d", "chains": ["DIRECT", "line", "cc-gate"], "rule": "Match", "upload": 519, "download": 803540,
            "start": "2026-10-21T17:07:05.572852+08:00",
            "metadata": ["host": "speed.cloudflare.com", "destinationIP": "", "destinationPort": "443", "remoteDestination": "162.159.140.220"],
        ]]]
        let row = LineEngine.parseConnections(root).first
        XCTAssertEqual(row?.host, "speed.cloudflare.com:443")
        XCTAssertEqual(row?.destination, "162.159.140.220")
        XCTAssertEqual(row?.chain, "line → DIRECT")  // travel order, gate hidden
        XCTAssertEqual(row?.download, 803540)
        XCTAssertNotNil(row?.start)  // microsecond timestamps parse
    }
}
