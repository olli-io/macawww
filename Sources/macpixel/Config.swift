import Foundation

/// The optional config file (SPEC §11). The daemon reads it one time, at start.
struct Config {
    var maxCacheMB = 512
    var transition = FxKind.burn
    /// The image of the screensaver (SPEC §18). nil: the wallpaper of each screen.
    var screensaver: String?
    /// The colour of the strip behind the menu bar (SPEC §5). nil: no strip.
    var menubar: UInt32?

    static var url: URL { Paths.home.appendingPathComponent(".config/macpixel/config") }

    static func load() -> Config {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return Config() }
        return parse(text)
    }

    static func parse(_ text: String) -> Config {
        var c = Config()
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].hasPrefix("#") else { continue }
            switch kv[0] {
            case "max_cache_mb": c.maxCacheMB = Int(kv[1]) ?? c.maxCacheMB
            case "transition":
                if let k = FxKind(rawValue: kv[1]) { c.transition = k } else {
                    logger.warning("config: bad transition \(kv[1], privacy: .public)")
                }
            case "screensaver": c.screensaver = kv[1].isEmpty ? nil : Paths.expand(kv[1])
            case "menubar":
                if kv[1].isEmpty { c.menubar = nil } else if let rgb = Target.parseColor(kv[1]) { c.menubar = rgb } else {
                    logger.warning("config: bad menubar \(kv[1], privacy: .public)")
                }
            default: logger.warning("config: unknown key \(kv[0], privacy: .public)")
            }
        }
        return c
    }
}
