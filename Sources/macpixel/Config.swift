import Foundation

/// The optional config file (SPEC §11). Read one time, at daemon start.
struct Config {
    var maxCacheMB = 512
    var transition = FxKind.burn
    /// Colour of the bar below the menu bar (SPEC §18). nil: no bar.
    var menuBarColor: UInt32?

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macpixel/config")
    }

    static func load() -> Config {
        var c = Config()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return c }
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].hasPrefix("#") else { continue }
            switch kv[0] {
            case "max_cache_mb": c.maxCacheMB = Int(kv[1]) ?? c.maxCacheMB
            case "transition":
                if let k = FxKind(rawValue: kv[1]) { c.transition = k } else {
                    logger.warning("config: bad transition \(kv[1], privacy: .public)")
                }
            case "menu_bar_color":
                if let v = Target.parseColor(kv[1]) { c.menuBarColor = v } else {
                    logger.warning("config: bad menu_bar_color \(kv[1], privacy: .public)")
                }
            default: logger.warning("config: unknown key \(kv[0], privacy: .public)")
            }
        }
        return c
    }
}
