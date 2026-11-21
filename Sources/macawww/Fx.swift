import Foundation

/// Name of a transition (SPEC §17).
enum FxKind: String {
    case burn, sweep, slide, wipe, disabled
    static let names = "burn, sweep, slide, wipe or disabled"
}

/// Linear congruential generator. No allocation.
struct Rng {
    var state: UInt64

    mutating func below(_ n: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(((state >> 32) &* UInt64(n)) >> 32)
    }
}

/// A transition on a grid of cells (SPEC §17). After the effects of ttfx.
/// This file has no AppKit code: `Transition` shows the grid.
final class Effect {
    static let gridW = 540, gridH = 270
    static let stepMs = 33

    // Display codes. A code with the top byte 0xFF is an opaque colour (0xFFRRGGBB).
    static let old: UInt32 = 0
    static let new: UInt32 = 1

    // burn
    static let igniteSteps = 60  // approximate steps until all cells burn
    static let fireSteps: UInt8 = 11  // steps for which a cell burns
    static let fire = gradient([0xFFFFFF, 0xFFF75D, 0xFE650D, 0x8A003C, 0x510100])
    static let smokeColors = gradient([0x504F4F, 0x6E6D6D, 0x8C8B8B, 0xA9A9A9, 0xC7C7C7])
    static let smokeSteps = 16, smokeMax = 2000, smokeOneIn = 64
    // sweep
    static let sweepSteps = 40
    static let shimmerSteps: UInt8 = 4
    static let sweepColors = gradient([0x8A008A, 0x4569C5, 0x00D1FF, 0x80E8FF, 0xFFFFFF])
    // wipe
    static let wipeSteps = 50
    static let wipeCellSteps: UInt8 = 4
    static let wipeColors = gradient([0x833AB4, 0xC02C69, 0xFD1D1D, 0xFC6731, 0xFCB045])
    // slide
    static let bandH = 6, slideSteps = 24
    static let bands = (gridH + bandH - 1) / bandH

    /// Cell stage: 0 = no change, 1...steps = shows colours, `done` = complete.
    private static let done = UInt8.max

    let kind: FxKind
    /// What each cell shows: a display code.
    private(set) var disp: [UInt32] = []
    private(set) var step = 0
    private var rng: Rng
    private var stage: [UInt8] = []
    /// The cells that show colours.
    private var active: [Int32] = []
    /// burn: the cells in the order in which they start to burn.
    private var order: [Int32] = []
    private var head = 0
    private var smoke: [(x: Int, y: Int, age: Int)] = []
    /// sweep, wipe: count of columns or diagonals that have started.
    private var groups = 0
    /// sweep, wipe: count of steps in this phase.
    private var t = 0

    init(kind: FxKind, seed: UInt64) {
        self.kind = kind
        rng = Rng(state: seed)
        guard kind != .slide else { return }  // slide has no grid: see `slideEdge`
        let n = Effect.gridW * Effect.gridH
        disp = [UInt32](repeating: Effect.old, count: n)
        stage = [UInt8](repeating: 0, count: n)
        active.reserveCapacity(n)  // each cell is in the list one time at most
        if kind == .burn {
            order = Effect.primsOrder(&rng)
            smoke.reserveCapacity(Effect.smokeMax)
        }
    }

    /// 8 opaque colours along 5 stops.
    static func gradient(_ stops: [UInt32]) -> [UInt32] {
        (0..<8).map { i in
            let seg = i * 4 / 7, t = UInt32(i * 4 % 7)
            let a = stops[seg], b = stops[min(seg + 1, 4)]
            var c: UInt32 = 0xFF00_0000
            for shift in [UInt32(0), 8, 16] {
                let ca = (a >> shift) & 0xFF, cb = (b >> shift) & 0xFF
                c |= ((ca * (7 - t) + cb * t) / 7) << shift
            }
            return c
        }
    }

    static func inOutQuad(_ t: Double) -> Double {
        if t < 0.5 { return 2 * t * t }
        let u = 2 - 2 * t
        return 1 - u * u / 2
    }

    /// The order in which the simple Prim's algorithm links the cells.
    static func primsOrder(_ rng: inout Rng) -> [Int32] {
        let w = gridW, h = gridH, n = w * h
        var linked = [Bool](repeating: false, count: n)
        var near = [0, 0, 0, 0]
        /// Puts the unlinked neighbours of `c` into `near`. Returns their count.
        func unlinked(_ c: Int) -> Int {
            let x = c % w, y = c / w
            var count = 0
            if y > 0, !linked[c - w] { near[count] = c - w; count += 1 }
            if x + 1 < w, !linked[c + 1] { near[count] = c + 1; count += 1 }
            if y + 1 < h, !linked[c + w] { near[count] = c + w; count += 1 }
            if x > 0, !linked[c - 1] { near[count] = c - 1; count += 1 }
            return count
        }
        let start = rng.below(n)
        var order: [Int32] = [Int32(start)]
        order.reserveCapacity(n)
        var edges = [start]
        while !edges.isEmpty {
            // The edge list has no order, so a swap with the last element is sufficient.
            let i = rng.below(edges.count)
            let current = edges[i]
            edges[i] = edges[edges.count - 1]
            edges.removeLast()
            let count = unlinked(current)
            if count == 0 { continue }
            let next = near[rng.below(count)]
            linked[current] = true
            linked[next] = true
            order.append(Int32(next))
            if count > 1 { edges.append(current) }
            if unlinked(next) > 0 { edges.append(next) }
        }
        return order
    }

    /// slide: the count of columns of `band` that show the new wallpaper at `step`.
    /// The band shows the new wallpaper moved `gridW - edge` cells to the left.
    static func slideEdge(band: Int, step: Int) -> Int {
        let local = step - band  // band b moves in the steps b+1 ... b+slideSteps
        if local <= 0 { return 0 }
        if local >= slideSteps { return gridW }
        return Int(inOutQuad(Double(local) / Double(slideSteps)) * Double(gridW))
    }

    /// (steps for which a cell shows colours, what it shows then)
    private var plan: (steps: UInt8, end: UInt32) {
        switch kind {
        case .burn: return (Effect.fireSteps, Effect.new)
        case .wipe: return (Effect.wipeCellSteps, Effect.new)
        default: return (Effect.shimmerSteps, Effect.new)
        }
    }

    /// What the cell shows at its stage, when no smoke is on it.
    private func base(_ cell: Int) -> UInt32 {
        let (steps, end) = plan
        let s = stage[cell]
        if s == 0 { return Effect.old }
        if s == Effect.done { return end }
        let i = Int(s) - 1
        switch kind {
        case .burn: return Effect.fire[i * 8 / Int(steps)]
        case .wipe: return Effect.wipeColors[i * 8 / Int(steps)]
        default:
            // a random colour, which stays for 2 steps
            if i % 2 == 1 { return disp[cell] }
            return Effect.sweepColors[rng.below(8)]
        }
    }

    private func start(_ cell: Int) {
        stage[cell] = 1
        active.append(Int32(cell))
        let code = base(cell)
        disp[cell] = code
    }

    /// Moves each active cell one stage on.
    private func runActive() {
        let (steps, end) = plan
        var i = 0
        while i < active.count {
            let cell = Int(active[i])
            stage[cell] += 1
            if stage[cell] <= steps {
                let code = base(cell)
                disp[cell] = code
                i += 1
                continue
            }
            stage[cell] = Effect.done
            active[i] = active[active.count - 1]
            active.removeLast()
            disp[cell] = end
            if kind == .burn, smoke.count < Effect.smokeMax, rng.below(Effect.smokeOneIn) == 0 {
                smoke.append((cell % Effect.gridW, cell / Effect.gridW, 0))
            }
        }
    }

    /// The groups that start in this step, for a move with `inOutQuad` across `total` groups.
    private func easedGroups(_ total: Int, steps: Int) -> Range<Int> {
        t += 1
        let p = Effect.inOutQuad(min(1, Double(t) / Double(steps)))
        let target = min(total, max(groups, Int((p * Double(total)).rounded())))
        let range = groups..<target
        groups = target
        return range
    }

    /// Goes to the next step. Returns false when the transition is complete:
    /// all cells show the new wallpaper. No allocation.
    func advance() -> Bool {
        let w = Effect.gridW, h = Effect.gridH, idle = active.isEmpty
        let complete: Bool
        switch kind {
        case .burn: complete = head == order.count && idle && smoke.isEmpty
        case .sweep: complete = groups == w && idle
        case .wipe: complete = groups == w + h - 1 && idle
        default: complete = step >= Effect.bands - 1 + Effect.slideSteps
        }
        if complete { return false }
        step += 1
        switch kind {
        case .burn: burn()
        case .sweep: sweep()
        case .wipe: wipe()
        default: break
        }
        return true
    }

    private func burn() {
        let w = Effect.gridW
        // remove the smoke from the cells
        for s in smoke {
            let cell = s.y * w + s.x
            let code = base(cell)
            disp[cell] = code
        }
        runActive()
        // new cells start to burn
        let perStep = (order.count + Effect.igniteSteps - 1) / Effect.igniteSteps
        let rate = min(perStep * (2 + rng.below(3)) / 3, order.count - head)
        for _ in 0..<rate {
            start(Int(order[head]))
            head += 1
        }
        // the smoke rises
        var i = 0
        while i < smoke.count {
            smoke[i].age += 1
            smoke[i].y -= 1
            smoke[i].x += rng.below(3) - 1
            let s = smoke[i]
            let shade = s.age * 8 / Effect.smokeSteps
            if shade >= 8 || s.y < 0 || s.x < 0 || s.x >= w {
                smoke[i] = smoke[smoke.count - 1]
                smoke.removeLast()
                continue
            }
            disp[s.y * w + s.x] = Effect.smokeColors[shade]
            i += 1
        }
    }

    private func sweep() {
        let w = Effect.gridW
        runActive()
        for group in easedGroups(w, steps: Effect.sweepSteps) {
            // from left to right
            for y in 0..<Effect.gridH { start(y * w + group) }
        }
    }

    private func wipe() {
        let w = Effect.gridW, h = Effect.gridH
        runActive()
        for d in easedGroups(w + h - 1, steps: Effect.wipeSteps) {
            // the diagonal x + y = d
            for x in max(0, d - (h - 1))...min(d, w - 1) { start((d - x) * w + x) }
        }
    }
}
