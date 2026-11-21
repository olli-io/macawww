import ImageIO
import XCTest
@testable import macpixel

final class ScreensTests: XCTestCase {
    func testIntegerScale() {
        // Exact fit.
        XCTAssertEqual(Screens.integerScale(art: (320, 208), screen: (2560, 1664)), 8)
        // 9.19 → 10: art × 10 covers the screen, the remainder is cut.
        XCTAssertEqual(Screens.integerScale(art: (320, 208), screen: (2940, 1912)), 10)
        // Width fits exactly at 6, the height is cut.
        XCTAssertEqual(Screens.integerScale(art: (320, 208), screen: (1920, 1080)), 6)
        XCTAssertEqual(Screens.integerScale(art: (1, 1), screen: (7, 5)), 7)
    }

    /// There is no aspect-fill fallback: the scale always covers the screen, the overflow is cut.
    func testNoFallback() {
        // 1.31 → 2.
        XCTAssertEqual(Screens.integerScale(art: (1470, 956), screen: (1920, 1080)), 2)
        XCTAssertEqual(Screens.integerScale(art: (100, 100), screen: (159, 159)), 2)
        // Wide art: the height sets the scale.
        XCTAssertEqual(Screens.integerScale(art: (3000, 200), screen: (2560, 1664)), 9)
        // Art larger than the screen: scale 1, cut on all sides.
        let a = Screens.placement(art: (4000, 3000), screen: (1920, 1080))
        XCTAssertEqual(a.k, 1)
        XCTAssertEqual(a.x, -1040)
        XCTAssertEqual(a.y, -960)
    }

    func testPlacement() {
        let a = Screens.placement(art: (480, 270), screen: (2940, 1912))
        XCTAssertEqual(a.k, 8)
        XCTAssertEqual(a.x, -450)
        XCTAssertEqual(a.y, -124)
        let b = Screens.placement(art: (320, 208), screen: (2560, 1664))
        XCTAssertEqual(b.x, 0)
        XCTAssertEqual(b.y, 0)
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
        try SystemWallpaper.renderStill(cache: url, to: png, width: sw, height: sh)
        let src = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        XCTAssertEqual(img.width, sw)
        XCTAssertEqual(img.height, sh)
        let out = Fixture.render(img, w: sw, h: sh)
        let at = Screens.placement(art: (w, h), screen: (sw, sh))
        XCTAssertEqual(at.k, 5)
        for y in 0..<sh {
            for x in 0..<sw {
                // Row 0 is the top row in both buffers. `at.y` is from the bottom.
                let ax = (x - at.x) / at.k, ay = (y - (sh - h * at.k - at.y)) / at.k
                for c in 0..<3 where out[(y * sw + x) * 4 + c] != f[(ay * w + ax) * 4 + c] {
                    return XCTFail("pixel \(x),\(y) differs")
                }
            }
        }
    }
}
