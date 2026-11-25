import XCTest
@testable import macpixel

final class StateTests: XCTestCase {
    func testParse() {
        let s = State.parse("""
            all img /a/b c.gif
            69734662 color #1A2B3C
            7 color 000000
            x img /bad/key.png
            all
            8 video /bad/kind.mp4
            9 color nothex
            10 dir /art/a dir

            """)
        XCTAssertEqual(s, ["all": .img("/a/b c.gif"), "69734662": .color(0x1A2B3C), "7": .color(0),
                           "10": .dir("/art/a dir")])
        XCTAssertEqual(Target.dir("/a b").line, "dir /a b")
        XCTAssertEqual(State.parse(""), [:])
    }

    func testTarget() {
        let s: [String: Target] = ["all": .img("/a.png"), "7": .color(0xFF0000)]
        XCTAssertEqual(State.target(s, display: 7), .color(0xFF0000))
        XCTAssertEqual(State.target(s, display: 8), .img("/a.png"))
        XCTAssertEqual(State.target(s, display: nil), .img("/a.png"))
        XCTAssertNil(State.target(["7": .color(0)], display: 8))
    }

    func testConfig() {
        let c = Config.parse("""
            # comment = ignored
            max_cache_mb = 64
            transition = wipe
            screensaver = ~/art/a b.gif
            other = 1
            """)
        XCTAssertEqual(c.maxCacheMB, 64)
        XCTAssertEqual(c.transition, .wipe)
        XCTAssertEqual(c.screensaver, Paths.home.appendingPathComponent("art/a b.gif").path)
        XCTAssertEqual(Config.parse("screensaver = /x/y.png").screensaver, "/x/y.png")
        XCTAssertNil(Config.parse("transition = burn").screensaver)
        XCTAssertNil(Config.parse("screensaver =").screensaver)
        XCTAssertNil(c.menubar)
        XCTAssertEqual(Config.parse("menubar = 141617").menubar, 0x141617)
        XCTAssertEqual(Config.parse("menubar = #A0b1C2").menubar, 0xA0B1C2)
        XCTAssertNil(Config.parse("menubar = black").menubar)
    }

    func testConfigRotation() {
        let d = Config.parse("transition = wipe")
        XCTAssertEqual(d.rotateInterval, 300)
        XCTAssertFalse(d.randomOrder)
        XCTAssertEqual(d.rotateKinds, [.wipe])
        let c = Config.parse("""
            rotate_interval = 60
            random_order = true
            rotate_transition = burn, rain
            """)
        XCTAssertEqual(c.rotateInterval, 60)
        XCTAssertTrue(c.randomOrder)
        XCTAssertEqual(c.rotateKinds, [.burn, .rain])
        XCTAssertEqual(Config.parse("rotate_transition = random").rotateKinds.count, FxKind.allCases.count - 1)
        // Bad values keep the default.
        let b = Config.parse("""
            rotate_interval = 5
            random_order = yes
            rotate_transition = fire
            """)
        XCTAssertEqual(b.rotateInterval, 300)
        XCTAssertFalse(b.randomOrder)
        XCTAssertEqual(b.rotateKinds, [.burn])
    }
}
