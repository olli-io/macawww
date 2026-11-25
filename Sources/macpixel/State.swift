import Foundation

enum Target: Equatable {
    case img(String)
    case color(UInt32)

    /// `#RRGGBB` or `RRGGBB`.
    static func parseColor(_ s: String) -> UInt32? {
        let h = s.hasPrefix("#") ? s.dropFirst() : Substring(s)
        guard h.count == 6, h.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(h, radix: 16)
    }

    var line: String {
        switch self {
        case .img(let p): return "img \(p)"
        case .color(let c): return "color " + String(format: "#%06X", c)
        }
    }
}

/// The state file (SPEC §11): one line per target, `<id|all> img <path>` or `<id|all> color <hex>`.
enum State {
    static var url: URL { Paths.supportDir.appendingPathComponent("state") }

    /// "all" or a display ID → state key.
    static func key(_ s: String) -> String? {
        s == "all" ? s : UInt32(s).map { String($0) }
    }

    static func parse(_ text: String) -> [String: Target] {
        var s: [String: Target] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard f.count == 3, let key = key(f[0]) else { continue }
            if f[1] == "img" {
                s[key] = .img(f[2])
            } else if f[1] == "color", let c = Target.parseColor(f[2]) {
                s[key] = .color(c)
            }
        }
        return s
    }

    static func load() -> [String: Target] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    /// The target of a display: its own line, else the `all` line.
    static func target(_ state: [String: Target], display: UInt32?) -> Target? {
        display.flatMap { state[String($0)] } ?? state["all"]
    }
}
