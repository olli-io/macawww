/// decrypt: symbols on black flood a random spanning tree of the symbols, as in smoke.
/// They flash white, become green and change at random. A second flood, from a different
/// symbol, starts before the first one stops. It makes each symbol flash white and show
/// the new wallpaper.
extension Effect {
    static let cipherColors: [UInt32] = [0xFF00_8000, 0xFF00_CB00, 0xFF00_FF00]
    /// Size of a symbol in cells. The glyph is 3 × 5; the remainder is a gap.
    static let symW = 4, symH = 6
    static let symCols = gridW / symW, symRows = gridH / symH
    static let syms = symCols * symRows
    /// Glyphs of 3 × 5 cells. Each octal digit is a row, from the top.
    static let glyphs: [UInt16] = [
        0o02720, 0o55255, 0o75557, 0o57575, 0o07070, 0o11244, 0o44211, 0o12421, 0o42124, 0o72222,
        0o22227, 0o64446, 0o31113, 0o74444, 0o11117, 0o55755, 0o25552, 0o71247, 0o74717, 0o20702,
        0o27222, 0o22272, 0o74747, 0o71717, 0o55222, 0o22555, 0o70707, 0o55555, 0o52525, 0o71111,
        0o44447, 0o55557,
    ]
    static let appearSteps = 30  // steps until all symbols have started
    /// The symbols get their solution from step `endFrom`, in `endSteps` steps, in the
    /// order of the second flood.
    static let endFrom = 16, endSteps = 40
    static let lifeMin = 14  // minimum steps from the start to the solution of a symbol
    static let shuffleOneIn = 4  // a green symbol changes with a probability of 1 / this
    /// Steps for which a symbol is white: when it is new, and when it has a solution.
    static let flashSteps = 3
    /// Symbols that start in one step.
    static let appearRate = (syms + appearSteps - 1) / appearSteps

    /// One flood for the start, and one from a different symbol for the end.
    func setupDecrypt() {
        let cols = Effect.symCols, rows = Effect.symRows, syms = Effect.syms
        order = Effect.floodOrder(&rng, cols, rows)
        ends = [Int32](repeating: 0, count: syms)
        for (r, sym) in order.enumerated() {
            ends[Int(sym)] = Int32(r / Effect.appearRate + 1 + Effect.lifeMin)
        }
        for (r, sym) in Effect.floodOrder(&rng, cols, rows).enumerated() {
            ends[Int(sym)] = max(ends[Int(sym)], Int32(Effect.endFrom + r * Effect.endSteps / syms))
        }
        stage = [UInt8](repeating: 0, count: syms)
    }

    /// Sets the cells of a symbol. `glyph`: its cells get `color`, the others black.
    /// Without it: only the cells of the glyph that the symbol shows get `color`.
    private func paint(_ sym: Int, _ color: UInt32, glyph: UInt16? = nil, all: Bool = false) {
        let origin = sym / Effect.symCols * Effect.symH * Effect.gridW + sym % Effect.symCols * Effect.symW
        for y in 0..<Effect.symH {
            for x in 0..<Effect.symW {
                let cell = origin + y * Effect.gridW + x
                if let glyph {
                    let on = x < 3 && y < 5 && glyph >> UInt16(14 - y * 3 - x) & 1 == 1
                    disp[cell] = on ? color : Effect.black
                } else if all || disp[cell] != Effect.black {
                    disp[cell] = color
                }
            }
        }
    }

    private func green() -> UInt32 { Effect.cipherColors[rng.below(Effect.cipherColors.count)] }

    private func randomGlyph() -> UInt16 { Effect.glyphs[rng.below(Effect.glyphs.count)] }

    /// Stages of a symbol: 1...`flashSteps` = white when new, then green until its end
    /// flash, `done` = the new wallpaper.
    func decrypt() {
        let flash = Effect.flashSteps
        for i in 0..<head {
            let sym = Int(order[i]), s = stage[sym]
            if s == Effect.done { continue }
            let left = max(0, Int(ends[sym]) - step)
            if left == 0 {
                stage[sym] = Effect.done
                groups += 1
                paint(sym, Effect.new, all: true)
            } else if left <= flash {
                if left == flash { paint(sym, Effect.white) }
            } else if s < flash {
                stage[sym] = s + 1
            } else if s == flash {
                stage[sym] = s + 1
                paint(sym, green())
            } else if rng.below(Effect.shuffleOneIn) == 0 {
                let color = green()
                paint(sym, color, glyph: randomGlyph())
            }
        }
        // new symbols start, in the order of the first flood
        let end = min(head + Effect.appearRate, Effect.syms)
        for i in head..<end {
            let sym = Int(order[i])
            stage[sym] = 1
            paint(sym, Effect.white, glyph: randomGlyph())
        }
        head = end
    }
}
