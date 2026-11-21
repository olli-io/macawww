import XCTest
@testable import macpixel

final class UpscaleTests: XCTestCase {
    private func factor(_ px: [UInt8], _ w: Int, _ h: Int, limit: Int = 0) -> Int {
        px.withUnsafeBytes { Upscale.factor($0.baseAddress!, width: w, height: h, limit: limit) }
    }

    private func holds(_ px: [UInt8], _ w: Int, _ h: Int, _ n: Int) -> Bool {
        px.withUnsafeBytes { Upscale.holds($0.baseAddress!, width: w, height: h, n: n) }
    }

    func testFactorAndRoundTrip() {
        for n in [1, 2, 3, 8] {
            let small = Fixture.frames(w: 13, h: 7, count: 1, seed: UInt64(n))[0]
            let big = Fixture.upscale(small, w: 13, h: 7, n: n)
            XCTAssertEqual(factor(big, 13 * n, 7 * n), n)
            XCTAssertTrue(holds(big, 13 * n, 7 * n, n))
            XCTAssertEqual(Fixture.shrink(big, w: 13 * n, h: 7 * n, n: n), small)
        }
    }

    func testOneWrongPixel() {
        let small = Fixture.frames(w: 10, h: 6, count: 1)[0]
        var big = Fixture.upscale(small, w: 10, h: 6, n: 4)
        XCTAssertEqual(factor(big, 40, 24), 4)
        big[(9 * 40 + 21) * 4] &+= 1  // one pixel in one block
        XCTAssertFalse(holds(big, 40, 24, 4))
        XCTAssertFalse(holds(big, 40, 24, 2))
        XCTAssertEqual(factor(big, 40, 24), 1)
    }

    func testLimitGivesDivisor() {
        let small = Fixture.frames(w: 5, h: 5, count: 1)[0]
        let big = Fixture.upscale(small, w: 5, h: 5, n: 6)
        XCTAssertEqual(factor(big, 30, 30, limit: 4), 2)
        XCTAssertEqual(factor(big, 30, 30, limit: 12), 6)
    }

    func testOneColour() {
        let px = [UInt8](repeating: 7, count: 48 * 32 * 4)
        XCTAssertEqual(factor(px, 48, 32), 16)
        XCTAssertEqual(factor([1, 2, 3, 4], 1, 1), 1)
    }

    func testSizeNotMultiple() {
        let px = [UInt8](repeating: 7, count: 10 * 10 * 4)
        XCTAssertFalse(holds(px, 10, 10, 4))
    }
}
