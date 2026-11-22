/// smoke: smoke floods a random spanning tree from a random cell, in the order of the
/// depth in the tree.
extension Effect {
    static let floodSteps = 60  // steps until all cells have smoke
    static let floodCellSteps: UInt8 = 16  // steps for which a cell has smoke
    static let floodColors = gradient([0x242424, 0xFFFFFF, 0xFFFFFF, 0x00D1FF, 0x8A008A])

    func flood() {
        runActive()
        let rate = (order.count + Effect.floodSteps - 1) / Effect.floodSteps
        for _ in 0..<min(rate, order.count - head) {
            start(Int(order[head]))
            head += 1
        }
    }
}
