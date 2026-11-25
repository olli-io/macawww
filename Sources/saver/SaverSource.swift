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
    /// The players of the files of the rotations, by path (SPEC §19).
    private static var loaded: [String: Player] = [:]
    private static var rotator: Rotator?
    private static var transition: Transition?
    /// All views. A rotation step changes the views that show its directory.
    private static let views = NSHashTable<MacpixelSaverView>.weakObjects()
    /// Count of the views that animate. The clock of the rotations runs only when it is not 0.
    private static var active = 0

    /// The cache directory in the container. Only for files that are not in the cache of the daemon.
    private static var localCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macpixel", isDirectory: true)
    }

    /// The `screensaver` image or directory of the config file, then the wallpaper of the display.
    static func candidates(config: Config, state: [String: Target], display: UInt32?) -> [Target] {
        var list: [Target] = []
        if let path = config.screensaver { list.append(Folder.isDirectory(path) ? .dir(path) : .img(path)) }
        if let t = State.target(state, display: display) { list.append(t) }
        return list
    }

    /// Calls `done` on the main thread with the first candidate that loads, and the
    /// directory when it is a rotation.
    static func resolve(display: UInt32?, done: @escaping (SaverContent, String?) -> Void) {
        let config = Config.load()
        if rotator == nil {
            let r = Rotator(interval: config.rotateInterval, random: config.randomOrder, kinds: config.rotateKinds)
            r.load = { path, done in
                load(path, pixelArt: true) { p in
                    if let p { loaded[path] = p }
                    done(p == nil ? MCWError.notPixelArt : nil)
                }
            }
            r.show = { rotated($0) }
            r.setRunning(active > 0)
            rotator = r
        }
        next(candidates(config: config, state: State.load(), display: display)[...], done)
    }

    private static func next(_ list: ArraySlice<Target>, _ done: @escaping (SaverContent, String?) -> Void) {
        switch list.first {
        case nil: done(.none, nil)
        case .color(let c): done(.color(c), nil)
        case .img(let path):
            load(path, pixelArt: false) { p in
                guard let p else { return next(list.dropFirst(), done) }
                done(.player(p), nil)
            }
        case .dir(let dir):
            guard let r = rotator else { return next(list.dropFirst(), done) }
            r.begin(dir) { err in
                guard err == nil, let f = r.file(dir), let p = loaded[f] else { return next(list.dropFirst(), done) }
                done(.player(p), dir)
            }
        }
    }

    /// Loads a file on the background queue. Calls `done` on the main thread with the player, nil on error.
    private static func load(_ path: String, pixelArt: Bool, done: @escaping (Player?) -> Void) {
        queue.async {
            let made = try? make(path, pixelArt: pixelArt)
            DispatchQueue.main.async {
                guard let made else { return done(nil) }
                let p = live[made.player.key]?.player ?? made.player
                live[p.key] = Weak(p)
                if made.wrote { clean() }
                done(p)
            }
        }
    }

    static func register(_ v: MacpixelSaverView) { views.add(v) }

    static func setActive(_ on: Bool) {
        active = max(0, active + (on ? 1 : -1))
        rotator?.setRunning(active > 0)
    }

    /// A rotation step: the views of the rotations show their new files, with one transition.
    private static func rotated(_ fx: FxKind) {
        transition?.end()
        let t = Transition(fx)
        for v in views.allObjects {
            guard let d = v.dir, let f = rotator?.file(d), let p = loaded[f] else { continue }
            t?.before(v)
            let changed = v.player !== p
            if changed { v.show(.player(p), dir: d) }
            t?.after(v, changed: changed)
        }
        let files = rotator?.files ?? []
        loaded = loaded.filter { files.contains($0.key) }
        if let t, t.start(onEnd: { transition = nil }) { transition = t }
    }

    /// The cache of the daemon, then the cache in the container, then a decode in this process.
    /// There is no child process here: the host process exits when the screensaver stops.
    /// `pixelArt`: an image that is not pixel art is an error (SPEC §19).
    private static func make(_ path: String, pixelArt: Bool) throws -> (player: Player, wrote: Bool) {
        let hash = try Decoder.hash(path: path)
        let dst = localCache.appendingPathComponent(hash + ".mcw")
        for url in [Cache.url(hash: hash), dst] {
            if let c = try? CacheFile(url: url) {
                return (try Player(key: hash, path: path, cache: Decoder.check(c, pixelArt: pixelArt)), false)
            }
        }
        try FileManager.default.createDirectory(at: localCache, withIntermediateDirectories: true)
        try Decoder.decode(url: URL(fileURLWithPath: path), to: dst, pixelArt: pixelArt)
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
