/// Name of a transition (SPEC §17).
enum FxKind: String, CaseIterable {
    case burn, sweep, slide, wipe, decrypt, pour, smoke, vhstape, rain, disabled
    static let names = "burn, sweep, slide, wipe, decrypt, pour, smoke, vhstape, rain or disabled"
}
