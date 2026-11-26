import ImageIO
import XCTest
@testable import macpixel

final class ScreensTests: XCTestCase {
    func testIntegerScale() {
        // Exact fit.
        XCTAssertEqual(Layout.integerScale(art: (320, 208), screen: (2560, 1664)), 8)
        // 9.19 → 10: art × 10 covers the screen, the remainder is cut.
        XCTAssertEqual(Layout.integerScale(art: (320, 208), screen: (2940, 1912)), 10)
        // Width fits exactly at 6, the height is cut.
        XCTAssertEqual(Layout.integerScale(art: (320, 208), screen: (1920, 1080)), 6)
        XCTAssertEqual(Layout.integerScale(art: (1, 1), screen: (7, 5)), 7)
    }

    /// There is no aspect-fill fallback: the scale always covers the screen, the overflow is cut.
    func testNoFallback() {
        // 1.31 → 2.
        XCTAssertEqual(Layout.integerScale(art: (1470, 956), screen: (1920, 1080)), 2)
        XCTAssertEqual(Layout.integerScale(art: (100, 100), screen: (159, 159)), 2)
        // Wide art: the height sets the scale.
        XCTAssertEqual(Layout.integerScale(art: (3000, 200), screen: (2560, 1664)), 9)
        // Art larger than the screen: scale 1, cut on all sides.
        let a = Layout.placement(art: (4000, 3000), screen: (1920, 1080))
        XCTAssertEqual(a.k, 1)
        XCTAssertEqual(a.x, -1040)
        XCTAssertEqual(a.y, -960)
    }

    func testBarHeight() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // Menu bar of 38 points, Dock of 70 points.
        XCTAssertEqual(Screens.barHeight(frame: frame, visible: CGRect(x: 0, y: 70, width: 1512, height: 874)), 38)
        // No menu bar on this screen.
        XCTAssertEqual(Screens.barHeight(frame: frame, visible: frame), 0)
        // A notch and a hidden menu bar: the notch area.
        XCTAssertEqual(Screens.barHeight(frame: frame, visible: frame, safeTop: 32), 32)
        // A second screen above the main screen.
        let top = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        XCTAssertEqual(Screens.barHeight(frame: top, visible: CGRect(x: 0, y: 982, width: 1920, height: 1055)), 25)
        // A second screen without separate Spaces: the visible frame has no menu bar, the window has one.
        XCTAssertEqual(Screens.barHeight(frame: frame, visible: frame, window: 30), 30)
    }

    func testMenuBarWindows() {
        let d1 = CGRect(x: 0, y: 0, width: 1470, height: 956), d2 = CGRect(x: 1470, y: 0, width: 2560, height: 1440)
        let windows = [CGRect(x: 0, y: 0, width: 1470, height: 33),     // menu bar of d1
                       CGRect(x: 1470, y: 0, width: 2560, height: 30),  // menu bar of d2
                       CGRect(x: 1600, y: 0, width: 300, height: 30),   // not the full width
                       CGRect(x: 1470, y: 40, width: 2560, height: 30), // not at the top
                       CGRect(x: 1470, y: 0, width: 2560, height: 1440)] // full screen
        XCTAssertEqual(Screens.menuBars(windows, displays: [(1, d1), (2, d2)]), [1: 33, 2: 30])
        XCTAssertEqual(Screens.menuBars([], displays: [(1, d1)]), [:])
    }

    func testPlacement() {
        let a = Layout.placement(art: (480, 270), screen: (2940, 1912))
        XCTAssertEqual(a.k, 8)
        XCTAssertEqual(a.x, -450)
        XCTAssertEqual(a.y, -124)
        let b = Layout.placement(art: (320, 208), screen: (2560, 1664))
        XCTAssertEqual(b.x, 0)
        XCTAssertEqual(b.y, 0)
    }

    func testImageFrame() {
        // Pixel art: 480×270 at k = 8 on 2940×1912 pixels, scale 2. The frame is in points.
        let a = Layout.imageFrame(art: (480, 270), size: CGSize(width: 1470, height: 956), scale: 2)
        XCTAssertEqual(a.frame, CGRect(x: -225, y: -62, width: 1920, height: 1080))
        XCTAssertEqual(a.gravity, .resize)
        // Other images fill the view.
        let b = Layout.imageFrame(art: nil, size: CGSize(width: 1470, height: 956), scale: 2)
        XCTAssertEqual(b.frame, CGRect(x: 0, y: 0, width: 1470, height: 956))
        XCTAssertEqual(b.gravity, .resizeAspectFill)
    }

    /// The PNG for the macOS desktop picture has the same scale and cut as the layer.
    func testRenderStill() throws {
        let w = 20, h = 12, sw = 70, sh = 50  // k = 5: 100×60, cut 15 px left/right and 5 px top/bottom
        var f = Fixture.frames(w: w, h: h, count: 1, seed: 3)[0]
        for i in stride(from: 3, to: f.count, by: 4) { f[i] = 255 }  // opaque
        let url = Fixture.tmpURL()
        let enc = try FrameEncoder(width: w, height: h, dst: url)
        f.withUnsafeBytes { _ = memcpy(enc.buffer, $0.baseAddress!, $0.count) }
        try enc.commit(delayMs: 0)
        try enc.finish(loopCount: 0, pixelArt: true)

        let png = Fixture.tmpURL("png")
        try SystemWallpaper.renderStill(cache: url, to: png, width: sw, height: sh, bar: (7, 0x141617))
        let src = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        XCTAssertEqual(img.width, sw)
        XCTAssertEqual(img.height, sh)
        let out = Fixture.render(img, w: sw, h: sh)
        let at = Layout.placement(art: (w, h), screen: (sw, sh))
        XCTAssertEqual(at.k, 5)
        for y in 0..<sh {
            for x in 0..<sw {
                // Row 0 is the top row in both buffers. `at.y` is from the bottom.
                let ax = (x - at.x) / at.k, ay = (y - (sh - h * at.k - at.y)) / at.k
                // The indexes are typed constants: one long expression is too slow to type-check.
                let o: Int = (y * sw + x) * 4
                let i: Int = (ay * w + ax) * 4
                if y < 7 {  // the menu bar strip. The byte order is B, G, R.
                    guard out[o] == 0x17, out[o + 1] == 0x16, out[o + 2] == 0x14 else {
                        return XCTFail("strip pixel \(x),\(y) differs")
                    }
                    continue
                }
                for c in 0..<3 where out[o + c] != f[i + c] {
                    return XCTFail("pixel \(x),\(y) differs")
                }
            }
        }
    }
}
