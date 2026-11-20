import AppKit
import os

let logger = Logger(subsystem: "io.macawww", category: "daemon")

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

struct Config {
    var maxCacheMB = 512

    static func load() -> Config {
        var c = Config()
        let url = Daemon.supportDir.appendingPathComponent("config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return c }
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].hasPrefix("#") else { continue }
            switch kv[0] {
            case "max_cache_mb": c.maxCacheMB = Int(kv[1]) ?? c.maxCacheMB
            default: logger.warning("config: unknown key \(kv[0], privacy: .public)")
            }
        }
        return c
    }
}

/// Unix socket server on the main queue. One request line, one reply line per connection.
final class Server {
    private let fd: Int32
    private let path: String
    private let source: DispatchSourceRead

    init?(path: String, handler: @escaping ([String], @escaping (Reply) -> Void) -> Void) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard withSockAddr(path, { bind(fd, $0, $1) }) == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
        self.path = path
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            guard let line = sockReadLine(c) else { Darwin.close(c); return }
            let respond = { (r: Reply) in
                sockWrite(c, r.line)
                Darwin.close(c)
            }
            guard let args = decodeJSONLine(line) as? [String], !args.isEmpty else {
                return respond(.err("bad request"))
            }
            handler(args, respond)
        }
        source.resume()
    }

    func stop() {
        source.cancel()
        Darwin.close(fd)
        unlink(path)
    }
}

/// Daemon: state, players, commands (SPEC §3, §11). Main thread only.
final class Daemon {
    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macawww", isDirectory: true)
    }
    private static var stateURL: URL { supportDir.appendingPathComponent("state") }
    private static var instance: Daemon?

    private let config = Config.load()
    private lazy var power = Power()
    private let screens = Screens()
    private lazy var wallpaper = SystemWallpaper(queue: queue)
    private var state: [String: Target] = [:]  // key: "all" or display ID
    private var players: [String: Player] = [:]  // key: path
    private var loading = Set<String>()
    private var server: Server?
    private var signals: [DispatchSourceSignal] = []
    private let queue = DispatchQueue(label: "io.macawww.decode", qos: .utility)

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let d = Daemon()
        instance = d
        d.start()
        app.run()
        exit(0)
    }

    /// "all" or a display ID → state key.
    static func targetKey(_ s: String) -> String? {
        s == "all" ? s : UInt32(s).map { String($0) }
    }

    private func start() {
        if Client.isRunning() {
            eprint("daemon already running")
            exit(0)  // not a crash: launchd must not restart
        }
        guard let s = Server(path: Client.socketPath, handler: { [self] in handle($0, $1) }) else {
            eprint("cannot listen on \(Client.socketPath)")
            exit(1)
        }
        server = s
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [self] in quit() }
            src.resume()
            signals.append(src)
        }
        state = loadState()
        power.onChange = { [self] in updatePause() }
        screens.onChange = { [self] in displaysChanged() }
        screens.onLayout = { [self] in wallpaper.sync($0) }
        wallpaper.start()
        power.start()
        screens.start()
        logger.info("daemon started")
    }

    private func quit() {
        server?.stop()
        exit(0)
    }

    // MARK: Commands

    private func handle(_ a: [String], _ reply: @escaping (Reply) -> Void) {
        switch (a[0], a.count) {
        case ("img", 3):
            guard let key = Daemon.targetKey(a[2]) else { return reply(.err("bad screen")) }
            let path = a[1]
            load(path) { [self] err in
                if let err { return reply(.err(Daemon.message(err))) }
                set(key, .img(path))
                reply(.ok())
            }
        case ("clear", 3):
            guard let key = Daemon.targetKey(a[2]), let c = Target.parseColor(a[1]) else {
                return reply(.err("bad argument"))
            }
            set(key, .color(c))
            reply(.ok())
        case ("query", 1): reply(.ok(["screens": query()]))
        case ("pause", 1): power.setUser(true); reply(.ok())
        case ("resume", 1): power.setUser(false); reply(.ok())
        case ("kill", 1):
            reply(.ok())
            DispatchQueue.main.async { [self] in quit() }
        default: reply(.err("unknown command"))
        }
    }

    private static func message(_ e: Error) -> String {
        (e as? MCWError)?.description ?? e.localizedDescription
    }

    private func set(_ key: String, _ t: Target) {
        if key == "all" { state = ["all": t] } else { state[key] = t }
        saveState()
        apply()
    }

    /// One object per screen: id, width, height, file or color, state, reasons.
    private func query() -> [[String: Any]] {
        screens.all.values.sorted { $0.id < $1.id }.map { s in
            var o: [String: Any] = ["id": s.id, "width": CGDisplayPixelsWide(s.id),
                                    "height": CGDisplayPixelsHigh(s.id)]
            guard let p = s.player else {
                o["color"] = String(format: "#%06X", s.color ?? 0)
                o["state"] = "static"
                return o
            }
            let r = power.reasons(windows: screens.windows(of: p))
            o["file"] = p.path
            o["state"] = p.isStatic ? "static" : p.isFinished ? "stopped" : r.isEmpty ? "playing" : "paused"
            if !p.isStatic && !p.isFinished && !r.isEmpty { o["reasons"] = r.list }
            return o
        }
    }

    // MARK: Players

    /// Decode on the background queue, then create the player on the main thread.
    private func load(_ path: String, done: @escaping (Error?) -> Void) {
        queue.async { [self] in
            let result = Result { () throws -> Player in
                let (hash, cache) = try Decoder.load(path: path)
                return try Player(key: hash, path: path, cache: cache)
            }
            DispatchQueue.main.async { [self] in
                switch result {
                case .failure(let e):
                    done(e)
                case .success(let p):
                    if players[path]?.key != p.key { players[path] = p }
                    Cache.evict(maxBytes: config.maxCacheMB << 20, keep: wallpaper.files.union(players.values.map(\.cacheURL)))
                    done(nil)
                }
            }
        }
    }

    private func ensureLoaded(_ path: String) {
        guard loading.insert(path).inserted else { return }
        load(path) { [self] err in
            loading.remove(path)
            if let err {
                logger.error("load \(path, privacy: .public): \(Daemon.message(err), privacy: .public)")
            } else {
                apply()
            }
        }
    }

    /// Show the target of each screen. Release players without layers.
    private func apply() {
        for s in screens.all.values {
            switch state[String(s.id)] ?? state["all"] ?? .color(0) {
            case .color(let c): screens.show(s, color: c)
            case .img(let path):
                if let p = players[path] { screens.show(s, player: p) } else { ensureLoaded(path) }
            }
        }
        let used = Set(screens.all.values.compactMap { $0.player.map(ObjectIdentifier.init) })
        players = players.filter { used.contains(ObjectIdentifier($0.value)) }
        updatePause()
    }

    private func displaysChanged() {
        for s in screens.all.values { s.player?.restoreInvariant() }
        apply()
    }

    private func updatePause() {
        var seen = Set<ObjectIdentifier>()
        for s in screens.all.values {
            guard let p = s.player, seen.insert(ObjectIdentifier(p)).inserted else { continue }
            p.setRunning(power.reasons(windows: screens.windows(of: p)).isEmpty)
        }
    }

    // MARK: State file

    private func loadState() -> [String: Target] {
        guard let text = try? String(contentsOf: Daemon.stateURL, encoding: .utf8) else { return [:] }
        var s: [String: Target] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard f.count == 3, let key = Daemon.targetKey(f[0]) else { continue }
            if f[1] == "img" {
                s[key] = .img(f[2])
            } else if f[1] == "color", let c = Target.parseColor(f[2]) {
                s[key] = .color(c)
            }
        }
        return s
    }

    private func saveState() {
        let text = state.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.line)\n" }.joined()
        do {
            try FileManager.default.createDirectory(at: Daemon.supportDir, withIntermediateDirectories: true)
            try text.write(to: Daemon.stateURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("save state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
