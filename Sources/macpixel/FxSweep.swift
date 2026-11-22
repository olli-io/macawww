/// sweep: a shimmer of colours goes from left to right and leaves the new wallpaper.
extension Effect {
    static let sweepSteps = 40  // steps of the sweep across the grid
    static let shimmerSteps: UInt8 = 4  // steps for which a cell shimmers
    static let sweepColors = gradient([0x8A008A, 0x4569C5, 0x00D1FF, 0x80E8FF, 0xFFFFFF])

    func sweep() {
        let w = Effect.gridW
        runActive()
        for group in easedGroups(w, steps: Effect.sweepSteps) {
            // from left to right
            for y in 0..<Effect.gridH { start(y * w + group) }
        }
    }
}
