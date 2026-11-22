import XCTest
@testable import macpixel

final class FxTests: XCTestCase {
    private let grid = [FxKind.burn, .sweep, .wipe, .decrypt, .pour, .smoke, .vhstape, .rain]

    func testGradients() {
        XCTAssertEqual(Effect.fire[0], 0xFFFF_FFFF)
        XCTAssertEqual(Effect.fire[7], 0xFF51_0100)
        XCTAssertEqual(Effect.smokeColors[0], 0xFF50_4F4F)
        XCTAssertEqual(Effect.smokeColors[7], 0xFFC7_C7C7)
    }

    func testEasing() {
        XCTAssertEqual(Effect.inOutQuad(0), 0)
        XCTAssertEqual(Effect.inOutQuad(0.5), 0.5)
        XCTAssertEqual(Effect.inOutQuad(1), 1)
    }

    func testKindNames() {
        XCTAssertEqual(FxKind(rawValue: "wipe"), .wipe)
        XCTAssertEqual(FxKind(rawValue: "vhstape"), .vhstape)
        // `names` has each kind
        XCTAssertEqual(FxKind.names.replacingOccurrences(of: " or", with: ",").components(separatedBy: ", "),
                       FxKind.allCases.map(\.rawValue))
        XCTAssertEqual(FxKind(rawValue: "disabled"), .disabled)
        XCTAssertNil(FxKind(rawValue: "melt"))
    }

    func testOrderHasEachCellOneTime() {
        var rng = Rng(state: 3)
        let order = Effect.primsOrder(&rng).sorted()
        XCTAssertEqual(order.count, Effect.gridW * Effect.gridH)
        XCTAssertTrue(order.enumerated().allSatisfy { $0.offset == Int($0.element) })
    }

    func testFloodOrderHasEachCellOneTime() {
        var rng = Rng(state: 3)
        let order = Effect.floodOrder(&rng, 40, 30)
        XCTAssertEqual(order.sorted(), (0..<1200).map { Int32($0) })
        // Each cell after the first one is adjacent to a cell that comes before it.
        var seen = Set([order[0]])
        for c in order.dropFirst() {
            let near = [c - 40, c + 40] + (c % 40 > 0 ? [c - 1] : []) + (c % 40 < 39 ? [c + 1] : [])
            XCTAssertTrue(near.contains { seen.contains($0) })
            seen.insert(c)
        }
    }

    func testTileOrderHasEachTileOneTime() {
        var rng = Rng(state: 3)
        let pour = Effect.tileOrder(&rng, tile: Effect.pourTile, zigzag: true)
        XCTAssertEqual(Array(pour.prefix(2)), [17 * 36, 17 * 36 + 1])  // the bottom row first
        XCTAssertEqual(pour[36], 17 * 36 - 1)  // then the row above it, from the right
        XCTAssertEqual(pour.sorted(), (0..<36 * 18).map { Int32($0) })
        let rain = Effect.tileOrder(&rng, tile: Effect.rainTile, zigzag: false)
        XCTAssertEqual(rain.sorted(), (0..<90 * 45).map { Int32($0) })
    }

    /// The first step shows only the old wallpaper, the last step only the new one.
    func testStartAndEnd() {
        for kind in grid {
            let fx = Effect(kind: kind, seed: 11)
            XCTAssertTrue(fx.disp.allSatisfy { $0 == Effect.old })
            XCTAssertTrue(fx.pieces.allSatisfy { $0.h == 0 })
            let count = fx.pieces.count
            var mixed = false
            while fx.advance() {
                mixed = mixed || fx.disp.contains { $0 != Effect.old && $0 != Effect.new }
                    || fx.pieces.contains { $0.w > 0 && $0.h > 0 }
                XCTAssertEqual(fx.pieces.count, count)
            }
            XCTAssertTrue(mixed)
            XCTAssertTrue((40..<200).contains(fx.step), "\(kind): \(fx.step) steps")
            XCTAssertTrue(fx.disp.allSatisfy { $0 == Effect.new }, "\(kind)")
            XCTAssertTrue(fx.pieces.allSatisfy { $0.w == 0 || $0.h == 0 }, "\(kind)")
            XCTAssertFalse(fx.advance())
        }
    }

    /// A piece is inside the grid, and its source also.
    func testPieces() {
        let w = Effect.gridW, h = Effect.gridH
        for kind in [FxKind.slide, .pour, .rain, .vhstape] {
            let fx = Effect(kind: kind, seed: 7)
            var srcs = Set<Int>()
            while fx.advance() {
                for p in fx.pieces where p.w > 0 && p.h > 0 {
                    srcs.insert(p.src)
                    XCTAssertTrue(p.x >= 0 && p.y >= 0 && p.x + p.w <= w && p.y + p.h <= h, "\(kind) \(p)")
                    XCTAssertTrue(p.dx >= 0 && p.dy >= 0 && p.y + p.h + p.dy <= h, "\(kind) \(p)")
                    // vhstape moves the old wallpaper out of the grid: black shows there
                    XCTAssertTrue(kind == .vhstape ? p.dx > 0 && p.dx <= 60 : p.x + p.w + p.dx <= w, "\(kind) \(p)")
                    if kind == .rain { XCTAssertTrue(p.w == 1 && p.h <= Effect.rainLen) }
                    if kind == .pour { XCTAssertTrue(p.w == Effect.pourTile && p.h <= Effect.pourTile) }
                }
            }
            XCTAssertEqual(srcs.isSubset(of: [0]), kind != .vhstape)
            XCTAssertEqual(srcs.isSubset(of: [1, 2, 3, 4]), kind == .vhstape)
        }
    }

    func testTint() {
        XCTAssertEqual(Tint.grey(0xFFFF_FFFF), 0xFFFF_FFFF)
        XCTAssertEqual(Tint.grey(0xFF00_FF00), 0xFF95_9595)
        let t = Tint.make(player: nil, color: 0x00FF00)
        XCTAssertEqual(t.count, 4)
        XCTAssertEqual(t[0].color?.components?.map { Int(($0 * 255).rounded()) }, [0x95, 0x95, 0x95, 255])
        XCTAssertEqual(t[1].color?.components?.map { Int(($0 * 255).rounded()) }, [0x95, 0, 0, 255])
        XCTAssertNil(t[0].surface)
    }

    /// Left half: colours. Right half: alpha 0 only where the cell shows the new wallpaper.
    func testRender() {
        let w = Effect.gridW, h = Effect.gridH
        for kind in grid {
            let fx = Effect(kind: kind, seed: 5)
            var px = [UInt32](repeating: 0xDEAD_BEEF, count: 2 * w * h)
            repeat {
                px.withUnsafeMutableBytes { fx.render($0.baseAddress!, stride: 2 * w * 4) }
                for cell in stride(from: 0, to: w * h, by: 7) {
                    let code = fx.disp[cell], i = cell / w * 2 * w + cell % w
                    let color: UInt32 = code >> 24 == 0xFF ? code : 0
                    XCTAssertEqual(px[i], color)
                    XCTAssertEqual(px[i + w], code == Effect.new ? 0 : 0xFF00_0000)
                }
            } while fx.advance()
            XCTAssertTrue(px.allSatisfy { $0 == 0 })
        }
    }

    func testSlide() {
        let w = Effect.gridW, last = Effect.bands - 1
        XCTAssertEqual(Effect.bands, 45)
        XCTAssertEqual(Effect.slideEdge(band: 0, step: 0), 0)
        // 4 bands start in 3 steps: band 4 starts at step 4, band 8 at step 7
        XCTAssertEqual(Effect.slideEdge(band: 4, step: 3), 0)
        XCTAssertGreaterThan(Effect.slideEdge(band: 4, step: 4), 0)
        XCTAssertEqual(Effect.slideEdge(band: 8, step: 6), 0)
        XCTAssertGreaterThan(Effect.slideEdge(band: 8, step: 7), 0)
        XCTAssertEqual(Effect.slideEdge(band: 0, step: Effect.slideSteps / 2), w / 2)
        XCTAssertEqual(Effect.slideEdge(band: 0, step: Effect.slideSteps), w)
        // The edge of a band does not go back.
        for step in 1..<100 {
            XCTAssertGreaterThanOrEqual(Effect.slideEdge(band: 7, step: step), Effect.slideEdge(band: 7, step: step - 1))
        }
        let fx = Effect(kind: .slide, seed: 1)
        while fx.advance() {}
        XCTAssertEqual(fx.step, 33 + Effect.slideSteps)
        XCTAssertFalse(fx.hasGrid)
        XCTAssertTrue(fx.pieces.allSatisfy { $0.w == w && $0.dx == 0 && $0.h == Effect.bandH })
        XCTAssertEqual(Effect.slideEdge(band: last, step: fx.step), w)
        XCTAssertLessThan(Effect.slideEdge(band: last, step: fx.step - 1), w)
    }

    func testPlacement() {
        // 4K: 8 × 540 = 4320, the sides are cut.
        let a = Transition.placement(screen: (3840, 2160))
        XCTAssertEqual(a.k, 8)
        XCTAssertEqual(a.x, -240)
        XCTAssertEqual(a.y, 0)
        let b = Transition.placement(screen: (2940, 1912))
        XCTAssertEqual(b.k, 8)
        XCTAssertEqual(b.y, -124)
        XCTAssertEqual(Transition.placement(screen: (540, 270)).k, 1)
    }
}
