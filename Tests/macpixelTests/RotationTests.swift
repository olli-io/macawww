import XCTest
@testable import macpixel

final class RotationTests: XCTestCase {
    private func dir(_ names: [String]) throws -> String {
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appendingPathComponent("macpixel-rotation-\(UUID().uuidString)")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        for n in names { fm.createFile(atPath: d.appendingPathComponent(n).path, contents: nil) }
        addTeardownBlock { try? fm.removeItem(at: d) }
        return d.path
    }

    private func name(path: String) -> String { (path as NSString).lastPathComponent }

    /// A loader that calls back at once. Files whose name starts with `x` are not pixel art.
    private let load: PixelArtLoader = { path, done in
        done((path as NSString).lastPathComponent.hasPrefix("x") ? MCWError.notPixelArt : nil)
    }

    func testAlphabeticalOrder() throws {
        let d = try dir(["b10.gif", "b2.png", "a.jpg", "notes.txt", ".hidden.gif"])
        let r = Rotation(dir: d, random: false)
        var shown: [String] = []
        for _ in 0..<4 {
            r.advance(load: { $1(nil) }) { XCTAssertNil($0) }
            shown.append(name(path: r.current!))
        }
        XCTAssertEqual(shown, ["a.jpg", "b2.png", "b10.gif", "a.jpg"])
    }

    func testSkipsFilesThatAreNotPixelArt() throws {
        let d = try dir(["a.png", "xb.png", "c.png", "xd.png"])
        let r = Rotation(dir: d, random: false)
        var shown: [String] = []
        for _ in 0..<3 {
            r.advance(load: load) { XCTAssertNil($0) }
            shown.append(name(path: r.current!))
        }
        XCTAssertEqual(shown, ["a.png", "c.png", "a.png"])
        XCTAssertEqual(Set(r.rejected.map { name(path: $0) }), ["xb.png", "xd.png"])
    }

    func testNoPixelArt() throws {
        let d = try dir(["xa.png", "xb.gif"])
        let r = Rotation(dir: d, random: false)
        var err: Error?
        r.advance(load: load) { err = $0 }
        XCTAssertEqual((err as? MCWError)?.description, "no pixel art in \(d)")
        XCTAssertNil(r.current)
        r.advance(load: { _, _ in XCTFail("rejected files are not tried again") }) { err = $0 }
        XCTAssertNotNil(err)
    }

    func testEmptyAndMissingDirectory() throws {
        var err: Error?
        Rotation(dir: try dir([]), random: false).advance(load: load) { err = $0 }
        XCTAssertNotNil(err)
        err = nil
        Rotation(dir: "/no/such/dir", random: false).advance(load: load) { err = $0 }
        XCTAssertNotNil(err)
    }

    func testRandomPassShowsEachFileOnce() throws {
        let names = (0..<7).map { "f\($0).png" }
        let d = try dir(names)
        let r = Rotation(dir: d, random: true)
        var shown: [String] = []
        for _ in 0..<(names.count * 3) {
            r.advance(load: { $1(nil) }) { XCTAssertNil($0) }
            shown.append(name(path: r.current!))
        }
        for pass in 0..<3 {
            XCTAssertEqual(Set(shown[pass * 7..<pass * 7 + 7]), Set(names))
        }
        // A file never shows two times in a row, also where a new pass starts.
        for i in 1..<shown.count { XCTAssertNotEqual(shown[i], shown[i - 1]) }
    }

    func testOneFile() throws {
        let d = try dir(["a.png"])
        for random in [false, true] {
            let r = Rotation(dir: d, random: random)
            for _ in 0..<3 {
                r.advance(load: { $1(nil) }) { XCTAssertNil($0) }
                XCTAssertEqual(r.current.map { name(path: $0) }, "a.png")
            }
        }
    }

    func testNewFilesJoin() throws {
        let d = try dir(["a.png", "c.png"])
        let r = Rotation(dir: d, random: false)
        r.advance(load: { $1(nil) }) { _ in }
        FileManager.default.createFile(atPath: (d as NSString).appendingPathComponent("b.png"), contents: nil)
        r.advance(load: { $1(nil) }) { _ in }
        XCTAssertEqual(r.current.map { name(path: $0) }, "b.png")
    }

    func testRotatorBegin() throws {
        let d = try dir(["xa.png", "b.png", "c.png"])
        let r = Rotator(interval: 10, random: false, kinds: [.wipe])
        r.load = load
        var err: Error? = MCWError.io("not called")
        r.begin(d) { err = $0 }
        XCTAssertNil(err)
        XCTAssertEqual(r.file(d).map { name(path: $0) }, "b.png")
        // A directory that rotates keeps its file.
        r.begin(d) { err = $0 }
        XCTAssertEqual(r.file(d).map { name(path: $0) }, "b.png")
        XCTAssertEqual(r.pick(), .wipe)
        r.keep([])
        XCTAssertNil(r.file(d))
        r.begin("/no/such/dir") { err = $0 }
        XCTAssertNotNil(err)
        XCTAssertNil(r.file("/no/such/dir"))
    }

    func testFxList() {
        XCTAssertEqual(FxKind.list("wipe"), [.wipe])
        XCTAssertEqual(FxKind.list("burn, rain,slide"), [.burn, .rain, .slide])
        XCTAssertEqual(FxKind.list("[burn, rain]"), [.burn, .rain])
        XCTAssertEqual(FxKind.list("random")?.count, FxKind.allCases.count - 1)
        XCTAssertFalse(FxKind.list("random")!.contains(.disabled))
        XCTAssertNil(FxKind.list("burn, fire"))
        XCTAssertNil(FxKind.list("burn,"))
        XCTAssertNil(FxKind.list(""))
    }

    func testDecodeOnlyPixelArt() throws {
        let fm = FileManager.default
        let d = URL(fileURLWithPath: try dir([]))
        let art = Fixture.png(w: 12, h: 9, n: 4, in: d, name: "art.png")
        let photo = Fixture.png(w: 12, h: 9, n: 1, in: d, name: "photo.png")
        let dst = Fixture.tmpURL()
        XCTAssertThrowsError(try Decoder.decode(url: photo, to: dst, pixelArt: true)) {
            XCTAssertEqual(($0 as? MCWError)?.description, MCWError.notPixelArt.description)
        }
        XCTAssertFalse(fm.fileExists(atPath: dst.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dst.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".\(dst.lastPathComponent)") }, [])
        try Decoder.decode(url: art, to: dst, pixelArt: true)
        XCTAssertTrue(try Decoder.check(CacheFile(url: dst), pixelArt: true).pixelArt)
        // A cache file that is not pixel art.
        let other = Fixture.tmpURL()
        try Decoder.decode(url: photo, to: other)
        XCTAssertNoThrow(try Decoder.check(CacheFile(url: other), pixelArt: false))
        XCTAssertThrowsError(try Decoder.check(CacheFile(url: other), pixelArt: true))
    }
}
