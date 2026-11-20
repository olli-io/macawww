import ImageIO
import XCTest
@testable import macawww

final class DecoderTests: XCTestCase {
    func testRoundTripSmall() throws {
        let f = Fixture.frames(w: 100, h: 70, count: 13)
        let c = try Fixture.encode(f, w: 100, h: 70)
        XCTAssertEqual(c.frameCount, f.count)
        XCTAssertEqual(Fixture.replay(c), f)
    }

    func testRoundTripManyRuns() throws {
        // 1000×700: the tile grid change gives > 64 runs.
        let f = Fixture.frames(w: 1000, h: 700, count: 8, seed: 7)
        let c = try Fixture.encode(f, w: 1000, h: 700)
        XCTAssertEqual(Fixture.replay(c), f)
        for fr in c.frames { XCTAssertLessThanOrEqual(fr.count, Diff.maxRects) }
    }

    func testOddSizes() throws {
        for (w, h) in [(1, 1), (33, 1), (1, 65), (37, 29)] {
            let f = Fixture.frames(w: w, h: h, count: 6, seed: UInt64(w * h))
            let c = try Fixture.encode(f, w: w, h: h)
            XCTAssertEqual(Fixture.replay(c), f, "\(w)x\(h)")
        }
    }

    func testFullFrameOverHalf() throws {
        // 64 tiles: the 3 spots of frame 1 are < 50 %. Frame 4 changes 75 %.
        let f = Fixture.frames(w: 256, h: 256, count: 5)
        let c = try Fixture.encode(f, w: 256, h: 256)
        XCTAssertTrue(c.frames[0].full)
        XCTAssertTrue(c.frames[4].full)
        XCTAssertFalse(c.frames[1].full)
    }

    func testDelayClamp() {
        XCTAssertEqual(Decoder.delayMs(0), 100)
        XCTAssertEqual(Decoder.delayMs(0.01), 100)
        XCTAssertEqual(Decoder.delayMs(0.019), 100)
        XCTAssertEqual(Decoder.delayMs(0.02), 20)
        XCTAssertEqual(Decoder.delayMs(0.05), 50)
        XCTAssertEqual(Decoder.delayMs(.nan), 100)
    }

    func testIdenticalFrameMerge() throws {
        let f = Fixture.frames(w: 40, h: 40, count: 3)
        let input = [f[0], f[1], f[1], f[1], f[2]]
        let c = try Fixture.encode(input, w: 40, h: 40, delays: [10, 20, 30, 40, 50])
        XCTAssertEqual(c.frames.map(\.delayMs), [10, 90, 50])
        XCTAssertEqual(Fixture.replay(c), f)
    }

    func testMergeRectsLimit() {
        let w = 640, h = 640, cols = 20
        var grid = [Bool](repeating: false, count: cols * cols)
        for i in stride(from: 0, to: grid.count, by: 3) { grid[i] = true }
        let rects = Diff.merge(grid: grid, width: w, height: h)
        XCTAssertLessThanOrEqual(rects.count, Diff.maxRects)
        // Each dirty tile is inside a rect.
        for i in stride(from: 0, to: grid.count, by: 3) {
            let x = (i % cols) * 32, y = (i / cols) * 32
            XCTAssertTrue(rects.contains { x >= $0.x && y >= $0.y && x + 32 <= $0.x + $0.w && y + 32 <= $0.y + $0.h })
        }
    }

    func testGIFFixture() throws {
        let delays = [0.01, 0.05, 0.07, 0.2]
        let url = Fixture.gif(w: 40, h: 30, delays: delays, same: [false, false, true, false])
        let dst = Fixture.tmpURL()
        try Decoder.decode(url: url, to: dst)
        let c = try CacheFile(url: dst)

        // Expected: ImageIO frames with consecutive duplicates collapsed.
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        var expected: [[UInt8]] = []
        for i in 0..<CGImageSourceGetCount(src) {
            let px = Fixture.render(CGImageSourceCreateImageAtIndex(src, i, nil)!, w: 40, h: 30)
            if expected.last != px { expected.append(px) }
        }
        XCTAssertEqual(c.width, 40)
        XCTAssertEqual(c.height, 30)
        XCTAssertEqual(Fixture.replay(c), expected)
        XCTAssertEqual(c.frames.first?.delayMs, 100)  // 10 ms clamped
        if c.frameCount == 3 { XCTAssertEqual(c.frames.map(\.delayMs), [100, 120, 200]) }
    }
}
