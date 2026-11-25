/// Name of a transition (SPEC §17).
enum FxKind: String, CaseIterable {
    case burn, sweep, slide, wipe, decrypt, pour, smoke, vhstape, rain, disabled
    static let names = "burn, sweep, slide, wipe, decrypt, pour, smoke, vhstape, rain or disabled"

    /// The transitions of a rotation (SPEC §19): one name, `random` (all kinds but `disabled`),
    /// or a list `a, b, c` (brackets are optional). Nil when a name is bad.
    static func list(_ s: String) -> [FxKind]? {
        if s == "random" { return allCases.filter { $0 != .disabled } }
        var t = Substring(s)
        if t.hasPrefix("["), t.hasSuffix("]") { t = t.dropFirst().dropLast() }
        let names = t.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let kinds = names.compactMap(FxKind.init(rawValue:))
        return kinds.count == names.count && !kinds.isEmpty ? kinds : nil
    }
}
