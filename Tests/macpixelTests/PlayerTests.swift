import XCTest
@testable import macpixel

final class PlayerTests: XCTestCase {
    /// Steps 3 loops and checks `front` after each tick (SPEC §8 invariant).
    private func check(w: Int, h: Int, n: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let f = Fixture.frames(w: w, h: h, count: n, seed: UInt64(n * 31 + w))
        let c = try Fixture.encode(f, w: w, h: h)
        XCTAssertEqual(c.frameCount, n, file: file, line: line)
        let p = try Player(key: "t", path: "t", cache: c)
        XCTAssertEqual(Fixture.read(p.front, w: w, h: h), f[0], file: file, line: line)
        for t in 1...(3 * n) {
            p.step()
            XCTAssertEqual(Fixture.read(p.front, w: w, h: h), f[t % n], "\(w)x\(h) n=\(n) tick \(t)",
                           file: file, line: line)
        }
        // Break the invariant mid-loop, then continue.
        p.restoreInvariant()
        for t in (3 * n + 1)...(5 * n) {
            p.step()
            XCTAssertEqual(Fixture.read(p.front, w: w, h: h), f[t % n], "after restore, tick \(t)",
                           file: file, line: line)
        }
    }

    func testInvariant1Frame() throws {
        try check(w: 64, h: 48, n: 1)
    }

    func testInvariant2Frames() throws {
        try check(w: 64, h: 48, n: 2)
        try check(w: 37, h: 29, n: 2)  // padded IOSurface stride
    }

    func testInvariant3Frames() throws {
        try check(w: 64, h: 48, n: 3)
        try check(w: 37, h: 29, n: 3)
    }

    func testInvariantManyFrames() throws {
        try check(w: 300, h: 200, n: 9)
    }

    func testLoopCountStops() throws {
        let f = Fixture.frames(w: 32, h: 32, count: 3)
        let c = try Fixture.encode(f, w: 32, h: 32, loop: 1)
        let p = try Player(key: "t", path: "t", cache: c)
        p.step()
        p.step()
        XCTAssertTrue(p.isFinished)
        p.step()
        XCTAssertEqual(Fixture.read(p.front, w: 32, h: 32), f[2])
    }

    func testStaticHasNoTimer() throws {
        let f = Fixture.frames(w: 16, h: 16, count: 1)
        let p = try Player(key: "t", path: "t", cache: try Fixture.encode(f, w: 16, h: 16))
        XCTAssertTrue(p.isStatic)
        p.setRunning(true)
        XCTAssertFalse(p.running)
    }
}
