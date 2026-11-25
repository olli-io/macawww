import Foundation

/// The directories of macpixel (SPEC §7, §11).
enum Paths {
    /// The home directory of the user. The screensaver host has a sandbox:
    /// there, `NSHomeDirectory()` gives the container and not this directory (SPEC §18).
    static let home: URL = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    static var supportDir: URL {
        home.appendingPathComponent("Library/Application Support/macpixel", isDirectory: true)
    }

    static var cacheDir: URL {
        home.appendingPathComponent("Library/Caches/macpixel", isDirectory: true)
    }

    /// An absolute path. `~` and `~/` are the home directory of the user.
    static func expand(_ path: String) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }
}
