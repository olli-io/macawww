/// slide: the new wallpaper comes in from the left, in bands of rows, one band after the
/// other. There is no grid: each band is a piece.
extension Effect {
    static let bandH = 6  // rows of cells in one band
    static let slideSteps = 24  // steps for which one band moves
    static let bands = (gridH + bandH - 1) / bandH
    /// The step at which the last band is complete.
    static let slideLast = slideStart(bands - 1) + slideSteps

    /// The step before `band` starts to move. 4 bands start in 3 steps.
    static func slideStart(_ band: Int) -> Int { band * 3 / 4 }

    /// The count of columns of `band` that show the new wallpaper at `step`.
    /// The band shows the new wallpaper moved `gridW - edge` cells to the left.
    static func slideEdge(band: Int, step: Int) -> Int {
        let local = step - slideStart(band)
        if local <= 0 { return 0 }
        if local >= slideSteps { return gridW }
        return Int(inOutQuad(Double(local) / Double(slideSteps)) * Double(gridW))
    }

    func slide() {
        let w = Effect.gridW, bandH = Effect.bandH
        for band in 0..<Effect.bands {
            let edge = Effect.slideEdge(band: band, step: step)
            let y = band * bandH
            pieces[band] = Piece(x: 0, y: y, w: edge, h: min(Effect.gridH, y + bandH) - y, dx: w - edge)
        }
    }
}
