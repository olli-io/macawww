import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import macpixel

final class CheckTests: XCTestCase {
    private func png(w: Int, h: Int, n: Int, in dir: URL, name: String) throws -> URL {
        Fixture.png(w: w, h: h, n: n, in: dir, name: name)
    }

    private func tmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testFactor() throws {
        let dir = try tmpDir()
        XCTAssertEqual(try Check.factor(png(w: 12, h: 9, n: 4, in: dir, name: "a.png")), 4)
        XCTAssertEqual(try Check.factor(png(w: 12, h: 9, n: 1, in: dir, name: "b.png")), 1)
    }

    func testFactorOfAllFrames() throws {
        // Frame 0 has one colour (factor 10). The square in frame 1 needs factor 2, as in the decoder.
        let url = Fixture.gif(w: 40, h: 30, delays: [0.05, 0.05, 0.05], same: [false, false, false], blank0: true)
        XCTAssertEqual(try Check.factor(url), 2)
    }

    func testListsOnlyTheImagesThatAreNotPixelArt() throws {
        let dir = try tmpDir()
        _ = try png(w: 12, h: 9, n: 4, in: dir, name: "art.png")
        let photo = try png(w: 12, h: 9, n: 1, in: dir, name: "photo.png")
        let broken = dir.appendingPathComponent("broken.gif")
        try Data("not an image".utf8).write(to: broken)
        try Data("text".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let bad = Check.rejected(dir.path)
        XCTAssertEqual(bad.map(\.url.lastPathComponent), ["broken.gif", "photo.png"])
        XCTAssertEqual(bad[1].reason, Check.notPixelArt)
        XCTAssertNotEqual(bad[0].reason, Check.notPixelArt)
        // A file gives only itself.
        XCTAssertEqual(Check.rejected(photo.path).map(\.url.lastPathComponent), ["photo.png"])
        XCTAssertEqual(Check.run(dir.appendingPathComponent("art.png").path), 0)
        XCTAssertEqual(Check.run(dir.path), 1)
    }
}
