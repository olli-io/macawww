import Foundation

/// Linear congruential generator. No allocation.
struct Rng {
    var state: UInt64

    mutating func below(_ n: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(((state >> 32) &* UInt64(n)) >> 32)
    }
}

/// A rect of cells that shows a wallpaper at a different position (SPEC §17).
/// `Transition` shows each piece with a clip layer. No piece shows when `w` or `h` is 0.
struct Piece: Equatable {
    /// The rect in cells. `y` is the top row.
    var x = 0, y = 0, w = 0, h = 0
    /// The wallpaper is moved this number of cells to the left and up.
    var dx = 0, dy = 0
    /// 0 = the new wallpaper. 1 = the old wallpaper in grey. 2, 3, 4 = only the red, green
    /// or blue channel of that grey.
    var src = 0
}

/// A transition on a grid of cells (SPEC §17). After the effects of ttfx.
/// Each effect has its own file (`Fx<Name>.swift`). This file has the parts that they share.
/// It has no AppKit code: `Transition` shows the grid and the pieces.
final class Effect {
    static let gridW = 540, gridH = 270
    static let stepMs = 33

    // Display codes. A code with the top byte 0xFF is an opaque colour (0xFFRRGGBB).
    static let old: UInt32 = 0
    static let new: UInt32 = 1
    static let black: UInt32 = 0xFF00_0000
    static let white: UInt32 = 0xFFFF_FFFF

    /// Cell stage: 0 = no change, 1...steps = shows colours, `done` = complete.
    static let done = UInt8.max

    let kind: FxKind
    /// What each cell shows: a display code. Empty for slide, which has only pieces.
    var disp: [UInt32] = []
    /// slide: the bands. pour, rain: the drops. vhstape: the lines. The count does not change.
    var pieces: [Piece] = []
    var step = 0
    var rng: Rng
    /// The stage of each cell. decrypt: the stage of each symbol.
    var stage: [UInt8] = []
    /// The cells that show colours.
    var active: [Int32] = []
    /// burn, smoke: the cells in the order in which they start.
    /// pour, rain: the tiles in the order in which their drops start.
    /// decrypt: the symbols in the order in which they start.
    var order: [Int32] = []
    /// decrypt: the end step of each symbol.
    var ends: [Int32] = []
    /// Count of the items of `order` that have started. vhstape: the top line of the wave.
    var head = 0
    var smoke: [(x: Int, y: Int, age: Int)] = []
    var drops: [Drop] = []
    var lines: [Line] = []
    /// sweep, wipe: count of columns or diagonals that have started.
    /// decrypt, vhstape: count of symbols or lines that show the new wallpaper.
    var groups = 0
    /// sweep, wipe: count of steps. vhstape: count of steps of noise that remain.
    var t = 0
    /// vhstape: the noise before the end has started.
    var second = false

    init(kind: FxKind, seed: UInt64) {
        self.kind = kind
        rng = Rng(state: seed)
        let w = Effect.gridW, h = Effect.gridH
        guard kind != .slide else {
            pieces = [Piece](repeating: Piece(), count: Effect.bands)
            return
        }
        disp = [UInt32](repeating: Effect.old, count: w * h)
        switch kind {
        case .burn:
            order = Effect.primsOrder(&rng)
            smoke.reserveCapacity(Effect.smokeMax)
        case .smoke: order = Effect.floodOrder(&rng, w, h)
        case .decrypt: setupDecrypt()
        case .pour, .rain: setupFall()
        case .vhstape:
            lines = [Line](repeating: Line(), count: h / Effect.lineH)
            pieces = [Piece](repeating: Piece(), count: lines.count)
        default: break
        }
        if [.burn, .sweep, .wipe, .smoke].contains(kind) {
            stage = [UInt8](repeating: 0, count: w * h)
            active.reserveCapacity(w * h)  // each cell is in the list one time at most
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

    /// The cells of a grid of `w` × `h` in the order of their depth in a random spanning tree.
    /// The tree grows from a random cell, each time to the adjacent cell with the lowest
    /// random weight (Prim's algorithm with weights on the cells).
    static func floodOrder(_ rng: inout Rng, _ w: Int, _ h: Int) -> [Int32] {
        let n = w * h, none = Int32.max
        // heap key: weight << 32 | cell
        var key = [UInt64](repeating: 0, count: n)
        for c in 0..<n { key[c] = UInt64(rng.below(1 << 30)) << 32 | UInt64(c) }
        /// In the tree: the depth. In the heap: the lowest depth that the cell can get.
        var depth = [Int32](repeating: none, count: n)
        var inTree = [Bool](repeating: false, count: n)
        var heap: [UInt64] = []
        heap.reserveCapacity(n)  // each cell is in the heap one time at most
        func push(_ k: UInt64) {
            var i = heap.count
            heap.append(k)
            while i > 0, heap[(i - 1) / 2] > k {
                heap[i] = heap[(i - 1) / 2]
                i = (i - 1) / 2
            }
            heap[i] = k
        }
        func pop() -> UInt64 {
            let top = heap[0], k = heap.removeLast()
            var i = 0
            while i < heap.count {  // false when the heap is empty now
                var child = 2 * i + 1
                if child + 1 < heap.count, heap[child + 1] < heap[child] { child += 1 }
                if child >= heap.count || heap[child] >= k { break }
                heap[i] = heap[child]
                i = child
            }
            if i < heap.count { heap[i] = k }
            return top
        }
        func reach(_ to: Int, _ d: Int32) {
            if inTree[to] { return }
            if depth[to] == none { push(key[to]) }
            depth[to] = min(depth[to], d)
        }
        var c = rng.below(n), deepest = 0
        depth[c] = 0
        while true {
            inTree[c] = true
            let x = c % w, y = c / w, d = depth[c]
            deepest = max(deepest, Int(d))
            if y > 0 { reach(c - w, d + 1) }
            if x + 1 < w { reach(c + 1, d + 1) }
            if y + 1 < h { reach(c + w, d + 1) }
            if x > 0 { reach(c - 1, d + 1) }
            if heap.isEmpty { break }
            c = Int(pop() & 0xFFFF_FFFF)
        }
        // counting sort by depth
        var at = [Int](repeating: 0, count: deepest + 2)
        for d in depth { at[Int(d) + 1] += 1 }
        for d in 1..<at.count { at[d] += at[d - 1] }
        var order = [Int32](repeating: 0, count: n)
        for c in 0..<n {
            order[at[Int(depth[c])]] = Int32(c)
            at[Int(depth[c])] += 1
        }
        return order
    }

    /// (steps for which a cell shows colours, what it shows then)
    var plan: (steps: UInt8, end: UInt32) {
        switch kind {
        case .burn: return (Effect.fireSteps, Effect.new)
        case .wipe: return (Effect.wipeCellSteps, Effect.new)
        case .smoke: return (Effect.floodCellSteps, Effect.new)
        default: return (Effect.shimmerSteps, Effect.new)
        }
    }

    /// What the cell shows at its stage, when no smoke is on it.
    func base(_ cell: Int) -> UInt32 {
        let (steps, end) = plan
        let s = stage[cell]
        if s == 0 { return Effect.old }
        if s == Effect.done { return end }
        let i = Int(s) - 1
        switch kind {
        case .burn: return Effect.fire[i * 8 / Int(steps)]
        case .wipe: return Effect.wipeColors[i * 8 / Int(steps)]
        case .smoke: return Effect.floodColors[i * 8 / Int(steps)]
        default:
            // a random colour, which stays for 2 steps
            if i % 2 == 1 { return disp[cell] }
            return Effect.sweepColors[rng.below(8)]
        }
    }

    func start(_ cell: Int) {
        stage[cell] = 1
        active.append(Int32(cell))
        let code = base(cell)
        disp[cell] = code
    }

    /// Moves each active cell one stage on.
    func runActive() {
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
            if kind == .burn { emitSmoke(cell) }
        }
    }

    /// The groups that start in this step, for a move with `inOutQuad` across `total` groups.
    func easedGroups(_ total: Int, steps: Int) -> Range<Int> {
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
        case .slide: complete = step >= Effect.slideLast
        case .decrypt: complete = groups == Effect.syms
        case .smoke: complete = head == order.count && idle
        case .pour, .rain: complete = head == order.count && drops.isEmpty
        case .vhstape: complete = groups == lines.count
        case .disabled: complete = true
        }
        if complete { return false }
        step += 1
        switch kind {
        case .burn: burn()
        case .sweep: sweep()
        case .wipe: wipe()
        case .slide: slide()
        case .decrypt: decrypt()
        case .smoke: flood()
        case .pour, .rain: fall()
        case .vhstape: vhstape()
        case .disabled: break
        }
        return true
    }
}
