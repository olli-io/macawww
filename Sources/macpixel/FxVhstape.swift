/// A band of `lineH` rows.
struct Line {
    /// Cells that the line is moved to the left.
    var shift = 0
    /// The shift of a jump.
    var jump = 0
    /// The steps that a jump stays. At the end: the steps until the line shows the new wallpaper.
    var hold = 0
}

/// vhstape: bands of rows lose their colour and jump to the side, a wave of such bands
/// moves down, and noise comes in bursts. Then noise covers all and each band, at a random
/// step, flashes white and shows the new wallpaper.
/// A moved line is a piece: it shows the old wallpaper in grey, moved to the left.
extension Effect {
    static let lineH = 6  // rows of cells in one line
    static let vhsGlitch = 50  // steps of the phase with lines that jump
    static let vhsWave = [24, 42, 24]  // the shifts of the 3 lines of the wave, in cells
    static let vhsSpeed = 10  // cells that a line moves in one step
    static let vhsLineOneIn = 6  // a line starts to jump with a probability of 1 / this
    static let vhsNoiseOneIn = 30  // a burst of noise starts with a probability of 1 / this
    /// Steps of a burst of noise, and of the noise before the end.
    static let vhsBurst = 6, vhsNoise = 14
    static let vhsEnd = 24  // the lines get the new wallpaper at random steps in this range
    static let vhsFlash = 3  // steps for which a line is white before the new wallpaper
    static let noiseColors: [UInt32] = [
        0xFF1E_1E1F, 0xFF3C_3B3D, 0xFF6D_6C70, 0xFFA2_A1A6, 0xFFCB_C9CF, 0xFFFF_FFFF,
    ]

    func vhstape() {
        let w = Effect.gridW, n = lines.count, waveN = Effect.vhsWave.count
        let glitch = step <= Effect.vhsGlitch
        t = max(0, t - 1)
        if glitch {
            // The wave moves in 1 of 2 steps: down in most cases. From the bottom, it goes
            // to a random line in the top half.
            if rng.below(2) == 0 {
                head = rng.below(10) < 7 ? head + 1 : max(0, head - 1)
                if head + waveN > n { head = rng.below(n / 2) }
            }
            // 3 lines at most jump at the same time
            var jumps = 0
            for l in lines where l.hold > 0 { jumps += 1 }
            if jumps < 3, rng.below(Effect.vhsLineOneIn) == 0 {
                let jump = 12 + rng.below(49), hold = 8 + rng.below(18)
                let i = rng.below(n)
                if lines[i].hold == 0, lines[i].shift == 0 {
                    lines[i].jump = jump
                    lines[i].hold = hold
                }
            }
            if t == 0, rng.below(Effect.vhsNoiseOneIn) == 0 { t = Effect.vhsBurst }
        }
        let end = second && t == 0
        let noise = second || t > 0
        var rest = true
        for i in 0..<n {
            let wave = glitch && i >= head && i < head + waveN
            let goal = !glitch ? 0 : wave ? Effect.vhsWave[i - head] : lines[i].hold > 0 ? lines[i].jump : 0
            let moves = lines[i].shift != goal
            if !moves, !second { lines[i].hold = max(0, lines[i].hold - 1) }
            lines[i].shift += min(Effect.vhsSpeed, max(-Effect.vhsSpeed, goal - lines[i].shift))
            let shift = lines[i].shift
            rest = rest && shift == 0

            var left = Int.max
            if end {
                if lines[i].hold == 0 { continue }
                lines[i].hold -= 1
                left = lines[i].hold
            }
            let cells = i * Effect.lineH * w..<(i + 1) * Effect.lineH * w
            if left <= Effect.vhsFlash {
                // the line is white, then shows the new wallpaper
                let code = left == 0 ? Effect.new : Effect.white
                if left == 0 { groups += 1 }
                for cell in cells { disp[cell] = code }
                pieces[i].h = 0
            } else if noise {
                // The noise changes each 2 steps, in runs of 1 to 4 cells.
                if step % 2 != 0 { continue }
                var run = 0
                var code: UInt32 = 0
                for cell in cells {
                    if run == 0 || cell % w == 0 {
                        run = 1 + rng.below(4)
                        code = Effect.noiseColors[rng.below(Effect.noiseColors.count)]
                    }
                    run -= 1
                    disp[cell] = code
                }
            } else {
                // The piece shows the line. The cells at its end are black.
                // A line that moves has a tint, which changes each step.
                let tint = moves ? 1 + step % 3 : 0
                pieces[i] = Piece(x: 0, y: i * Effect.lineH, w: w, h: shift == 0 ? 0 : Effect.lineH,
                                  dx: shift, src: 1 + tint)
                for cell in cells { disp[cell] = cell % w + shift >= w ? Effect.black : Effect.old }
            }
        }
        if !glitch, rest, !second {
            second = true
            t = Effect.vhsNoise
            for i in 0..<n { lines[i].hold = 1 + Effect.vhsFlash + rng.below(Effect.vhsEnd) }
        }
    }
}
