/// burn: a fire starts at a random cell and spreads in the order of a random spanning tree
/// (the simple Prim's algorithm). Some cells emit smoke.
extension Effect {
    static let igniteSteps = 60  // approximate steps until all cells burn
    static let fireSteps: UInt8 = 11  // steps for which a cell burns
    static let fire = gradient([0xFFFFFF, 0xFFF75D, 0xFE650D, 0x8A003C, 0x510100])
    static let smokeColors = gradient([0x504F4F, 0x6E6D6D, 0x8C8B8B, 0xA9A9A9, 0xC7C7C7])
    static let smokeSteps = 16, smokeMax = 2000, smokeOneIn = 64

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

    /// A cell that stops burning can emit smoke.
    func emitSmoke(_ cell: Int) {
        if smoke.count < Effect.smokeMax, rng.below(Effect.smokeOneIn) == 0 {
            smoke.append((cell % Effect.gridW, cell / Effect.gridW, 0))
        }
    }

    func burn() {
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
}
