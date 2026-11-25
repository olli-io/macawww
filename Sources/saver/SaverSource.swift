import Foundation

/// What a screensaver view shows (SPEC §18).
enum SaverContent {
    case player(Player)
    case color(UInt32)
    case none
}

/// Selects and loads the content of a screensaver view (SPEC §18).
/// The host has a sandbox: it can read all files, and write only in its container.
enum SaverSource {
    private final class Weak {
        weak var player: Player?
        init(_ p: Player) { player = p }
    }

    private static let queue = DispatchQueue(label: "io.macpixel.saver.decode", qos: .userInitiated)
    /// The players in use, by file hash. Views that show the same file share one player. Main thread only.
    private static var live: [String: Weak] = [:]

    /// The cache directory in the container. Only for files that are not in the cache of the daemon.
    private static var localCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macpixel", isDirectory: true)
    }

    /// The `screensaver` image of the config file, then the wallpaper of the display.
    static func candidates(config: Config, state: [String: Target], display: UInt32?) -> [Target] {
        var list: [Target] = []
        if let path = config.screensaver { list.append(.img(path)) }
        if let t = State.target(state, display: display) { list.append(t) }
        return list
    }

    /// Calls `done` on the main thread with the first candidate that loads.
    static func resolve(display: UInt32?, done: @escaping (SaverContent) -> Void) {
        next(candidates(config: Config.load(), state: State.load(), display: display)[...], done)
    }

    private static func next(_ list: ArraySlice<Target>, _ done: @escaping (SaverContent) -> Void) {
        switch list.first {
        case nil: done(.none)
        case .color(let c): done(.color(c))
        case .img(let path):
            queue.async {
                let made = try? make(path)
                DispatchQueue.main.async {
                    guard let made else { return next(list.dropFirst(), done) }
                    let p = live[made.player.key]?.player ?? made.player
                    live[p.key] = Weak(p)
                    if made.wrote { clean() }
                    done(.player(p))
                }
            }
        }
    }

    /// The cache of the daemon, then the cache in the container, then a decode in this process.
    /// There is no child process here: the host process exits when the screensaver stops.
    private static func make(_ path: String) throws -> (player: Player, wrote: Bool) {
        let hash = try Decoder.hash(path: path)
        if let c = try? CacheFile(url: Cache.url(hash: hash)) {
            return (try Player(key: hash, path: path, cache: c), false)
        }
        let dst = localCache.appendingPathComponent(hash + ".mcw")
        if let c = try? CacheFile(url: dst) {
            return (try Player(key: hash, path: path, cache: c), false)
        }
        try FileManager.default.createDirectory(at: localCache, withIntermediateDirectories: true)
        try Decoder.decode(url: URL(fileURLWithPath: path), to: dst)
        return (try Player(key: hash, path: path, cache: try CacheFile(url: dst)), true)
    }

    /// Deletes the files of the container cache that no player uses.
    private static func clean() {
        let keep = Set(live.values.compactMap { $0.player?.cacheURL })
        let dir = localCache
        // Not in a sandbox (a test host): this is the cache of the daemon. Do not delete its files.
        guard dir.standardizedFileURL != Cache.dir.standardizedFileURL else { return }
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "mcw" && !keep.contains(f.path) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}
