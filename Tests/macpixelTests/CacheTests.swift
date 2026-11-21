import XCTest
@testable import macpixel

final class CacheTests: XCTestCase {
    private func validFile() throws -> URL {
        let c = try Fixture.encode(Fixture.frames(w: 70, h: 50, count: 5), w: 70, h: 50, loop: 3)
        return c.url
    }

    private func mutated(_ url: URL, _ change: (inout Data) -> Void) throws -> URL {
        var d = try Data(contentsOf: url)
        change(&d)
        let out = Fixture.tmpURL()
        try d.write(to: out)
        return out
    }

    func testReadBack() throws {
        let c = try CacheFile(url: try validFile())
        XCTAssertEqual(c.width, 70)
        XCTAssertEqual(c.height, 50)
        XCTAssertEqual(c.frameCount, 5)
        XCTAssertEqual(c.loopCount, 3)
        XCTAssertTrue(c.frames[0].full)
        for r in c.rects { XCTAssertEqual(r.offset % 16, 0) }
        for f in c.frames { XCTAssertLessThanOrEqual(f.count, Diff.maxRects) }
    }

    func testBadMagic() throws {
        let u = try mutated(try validFile()) { $0[0] ^= 0xFF }
        XCTAssertThrowsError(try CacheFile(url: u))
    }

    func testBadVersion() throws {
        let u = try mutated(try validFile()) { $0[4] &+= 1 }
        XCTAssertThrowsError(try CacheFile(url: u))
    }

    func testTruncated() throws {
        let src = try validFile()
        for cut in [1, 9, 400] {
            let u = try mutated(src) { $0.removeLast(cut) }
            XCTAssertThrowsError(try CacheFile(url: u), "cut \(cut)")
        }
        let u = try mutated(src) { $0 = $0.prefix(10) }
        XCTAssertThrowsError(try CacheFile(url: u))
    }

    func testBadIndexOffset() throws {
        let u = try mutated(try validFile()) { d in
            for i in 24..<32 { d[i] = 0xFF }
        }
        XCTAssertThrowsError(try CacheFile(url: u))
    }
}
