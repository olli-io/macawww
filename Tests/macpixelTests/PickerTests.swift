import XCTest
@testable import macpixel

final class PickerTests: XCTestCase {
    func testImagesFilterAndOrder() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("macpixel-picker-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("dir.gif"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for name in ["b10.gif", "b2.GIF", "a.png", "c.jpg", "d.jpeg", "e.txt", ".hidden.gif", "noext"] {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
        }
        XCTAssertEqual(Folder.images(in: dir).map(\.lastPathComponent),
                       ["a.png", "b2.GIF", "b10.gif", "c.jpg", "d.jpeg"])
        XCTAssertEqual(Folder.images(in: dir.appendingPathComponent("missing")), [])
    }

    func testScrollTop() {
        XCTAssertEqual(Picker.scrollTop(0, selected: 0, rows: 5), 0)
        XCTAssertEqual(Picker.scrollTop(0, selected: 4, rows: 5), 0)
        XCTAssertEqual(Picker.scrollTop(0, selected: 5, rows: 5), 1)
        XCTAssertEqual(Picker.scrollTop(3, selected: 2, rows: 5), 2)
        XCTAssertEqual(Picker.scrollTop(3, selected: 5, rows: 5), 3)
    }

    func testLine() {
        XCTAssertEqual(Picker.line("a.gif", selected: false, cols: 80), "  a.gif")
        XCTAssertEqual(Picker.line("a.gif", selected: true, cols: 80), "\u{1B}[7m> a.gif\u{1B}[0m")
        XCTAssertEqual(Picker.line("abcdefgh.gif", selected: false, cols: 8), "  abcde")
    }
}
