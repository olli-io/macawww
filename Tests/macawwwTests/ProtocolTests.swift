import XCTest
@testable import macawww

final class ProtocolTests: XCTestCase {
    func testRequestRoundTrip() {
        let args = ["img", "/tmp/a b\tc\nd \"e\" ä/😀.gif", "all", "config"]
        let line = encodeJSONLine(args)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertEqual(decodeJSONLine(String(line.dropLast())) as? [String], args)
    }

    func testReplies() {
        let ok = decodeJSONLine(Reply.ok().line) as? [String: Any]
        XCTAssertEqual(ok?["ok"] as? Bool, true)
        let err = decodeJSONLine(Reply.err("bad\nthing").line) as? [String: Any]
        XCTAssertEqual(err?["ok"] as? Bool, false)
        XCTAssertEqual(err?["error"] as? String, "bad\nthing")
        XCTAssertEqual(Reply.err("x\ny").line.filter { $0 == "\n" }.count, 1)
    }

    func testScreenLine() {
        XCTAssertEqual(Client.screenLine(["id": 1, "width": 3840, "height": 2160, "file": "/a b.gif",
                                          "state": "paused", "reasons": ["occluded", "user"]]),
                       "1 3840x2160 /a b.gif paused (occluded,user)")
        XCTAssertEqual(Client.screenLine(["id": 2, "width": 1920, "height": 1080, "color": "#000000",
                                          "state": "static"]),
                       "2 1920x1080 color #000000 static")
    }
}
