/// wipe: a diagonal band of colours goes from the top left to the bottom right and leaves
/// the new wallpaper.
extension Effect {
    static let wipeSteps = 50  // steps of the wipe across the grid
    static let wipeCellSteps: UInt8 = 4  // steps for which a cell shows the colours
    static let wipeColors = gradient([0x833AB4, 0xC02C69, 0xFD1D1D, 0xFC6731, 0xFCB045])

    func wipe() {
        let w = Effect.gridW, h = Effect.gridH
        runActive()
        for d in easedGroups(w + h - 1, steps: Effect.wipeSteps) {
            // the diagonal x + y = d
            for x in max(0, d - (h - 1))...min(d, w - 1) { start((d - x) * w + x) }
        }
    }
}
