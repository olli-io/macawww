import XCTest
@testable import macawww

final class FxTests: XCTestCase {
    private let grid = [FxKind.burn, .sweep, .wipe]

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
        XCTAssertEqual(FxKind(rawValue: "disabled"), .disabled)
        XCTAssertNil(FxKind(rawValue: "melt"))
    }

    func testOrderHasEachCellOneTime() {
        var rng = Rng(state: 3)
        let order = Effect.primsOrder(&rng).sorted()
        XCTAssertEqual(order.count, Effect.gridW * Effect.gridH)
        XCTAssertTrue(order.enumerated().allSatisfy { $0.offset == Int($0.element) })
    }

    /// The first step shows only the old wallpaper, the last step only the new one.
    func testStartAndEnd() {
        for kind in grid {
            let fx = Effect(kind: kind, seed: 11)
            XCTAssertTrue(fx.disp.allSatisfy { $0 == Effect.old })
            var mixed = false
            while fx.advance() {
                mixed = mixed || fx.disp.contains { $0 != Effect.old && $0 != Effect.new }
            }
            XCTAssertTrue(mixed)
            XCTAssertTrue((40..<200).contains(fx.step), "\(kind): \(fx.step) steps")
            XCTAssertTrue(fx.disp.allSatisfy { $0 == Effect.new }, "\(kind)")
            XCTAssertFalse(fx.advance())
        }
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
        XCTAssertEqual(Effect.slideEdge(band: 3, step: 3), 0)
        XCTAssertEqual(Effect.slideEdge(band: 0, step: Effect.slideSteps / 2), w / 2)
        XCTAssertEqual(Effect.slideEdge(band: 0, step: Effect.slideSteps), w)
        // The edge of a band does not go back.
        for step in 1..<100 {
            XCTAssertGreaterThanOrEqual(Effect.slideEdge(band: 7, step: step), Effect.slideEdge(band: 7, step: step - 1))
        }
        let fx = Effect(kind: .slide, seed: 1)
        while fx.advance() {}
        XCTAssertEqual(fx.step, last + Effect.slideSteps)
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
