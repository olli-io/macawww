/// A drop or a tile that falls. It covers the rows `tail...y`.
struct Drop {
    var x: Int
    var y = -1
    var tail = 0
    /// The row at which the fall stops.
    var to: Int
    var age = 0
    /// Number of steps of the fall.
    var steps: Int
}

/// rain and pour, which have the same code.
/// - pour: tiles fall from the top and fill the grid from the bottom, each row in the
///   opposite direction to the row below.
/// - rain: drops fall from the top. Each drop fills one tile, from the bottom row of tiles up.
/// A drop is a piece: it shows the new wallpaper of its tile, moved up.
extension Effect {
    static let pourTile = 15
    static let pourRate = 7  // tiles that start to fall in one step
    /// Number of steps of a fall: the minimum, and the size of the random range.
    static let pourSteps = (10, 6)

    static let rainTile = 6
    static let rainRate = 68  // drops that start to fall in one step
    /// The drops come at random from this number of the lowest empty tile rows.
    static let rainRows = 3
    static let rainSteps = (10, 8)
    static let rainLen = 5  // maximum length of a drop in cells

    private var fallPlan: (tile: Int, rate: Int, steps: (Int, Int)) {
        kind == .pour ? (Effect.pourTile, Effect.pourRate, Effect.pourSteps)
            : (Effect.rainTile, Effect.rainRate, Effect.rainSteps)
    }

    /// The tiles of side `tile`, from the bottom row up. With `zigzag`, each row has the
    /// opposite direction to the row below. Without it, each tile changes position with a
    /// random tile of the subsequent `rainRows` rows.
    static func tileOrder(_ rng: inout Rng, tile: Int, zigzag: Bool) -> [Int32] {
        let cols = gridW / tile, rows = gridH / tile
        var order: [Int32] = []
        order.reserveCapacity(cols * rows)
        for i in 0..<rows {
            for tx in 0..<cols {
                let x = zigzag && i % 2 == 1 ? cols - 1 - tx : tx
                order.append(Int32((rows - 1 - i) * cols + x))
            }
        }
        if !zigzag {
            for i in 0..<order.count {
                let span = min(rainRows * cols, order.count - i)
                order.swapAt(i, i + rng.below(span))
            }
        }
        return order
    }

    func setupFall() {
        let (tile, rate, steps) = fallPlan
        order = Effect.tileOrder(&rng, tile: tile, zigzag: kind == .pour)
        // A fall has `steps.0 + steps.1 - 1` steps at most.
        let most = rate * (steps.0 + steps.1 - 1)
        drops.reserveCapacity(most)
        pieces = [Piece](repeating: Piece(), count: most)
    }

    func fall() {
        let w = Effect.gridW, pour = kind == .pour
        let (tile, rate, steps) = fallPlan
        let cols = w / tile
        // new drops start above the top row
        for _ in 0..<min(rate, order.count - head) {
            let t = Int(order[head])
            head += 1
            let x = pour ? 0 : rng.below(tile)
            drops.append(Drop(x: t % cols * tile + x, to: t / cols * tile + tile - 1,
                              steps: steps.0 + rng.below(steps.1)))
        }
        var i = 0
        while i < drops.count {
            drops[i].age += 1
            let d = drops[i]
            // pour: in_quad. rain: in_quart, as in ttfx
            var p = Double(d.age) / Double(d.steps)
            p = pour ? p * p : p * p * p * p
            let y = Int(p * Double(d.to + 1)) - 1
            drops[i].tail = pour ? y + 1 - tile : min(max(d.y + 1, y + 1 - Effect.rainLen), y)
            drops[i].y = y
            if d.age < d.steps {
                i += 1
                continue
            }
            // the drop is at its tile
            drops[i] = drops[drops.count - 1]
            drops.removeLast()
            let x0 = d.x / tile * tile, y0 = d.to + 1 - tile
            for cy in y0..<y0 + tile {
                for cell in cy * w + x0..<cy * w + x0 + tile { disp[cell] = Effect.new }
            }
        }
        for i in 0..<pieces.count {
            guard i < drops.count else {
                pieces[i].h = 0
                continue
            }
            let d = drops[i], top = max(d.tail, 0)
            pieces[i] = Piece(x: d.x, y: top, w: pour ? tile : 1, h: max(0, d.y - top + 1), dy: d.to - d.y)
        }
    }
}
