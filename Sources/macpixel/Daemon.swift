import AppKit
import os

/// Daemon: state, players, commands (SPEC §3, §11). Main thread only.
final class Daemon {
    private static var instance: Daemon?

    private let config = Config.load()
    private lazy var power = Power()
    private let screens = Screens()
    private lazy var wallpaper = SystemWallpaper(queue: queue)
    private var state: [String: Target] = [:]  // key: "all" or display ID
    private var players: [String: Player] = [:]  // key: path
    private var transition: Transition?
    /// The windows that show `transition`.
    private var fxWindows: [(window: NSWindow, display: CGDirectDisplayID)] = []
    private lazy var rotator = Rotator(interval: config.rotateInterval, random: config.randomOrder,
                                       kinds: config.rotateKinds)
    /// A rotation step that waits for the end of `transition`.
    private var rotationFx: FxKind?
    private var loading = Set<String>()
    private var server: Server?
    private var signals: [DispatchSourceSignal] = []
    private let queue = DispatchQueue(label: "io.macpixel.decode", qos: .utility)

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let d = Daemon()
        instance = d
        d.start()
        app.run()
        exit(0)
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
        state = State.load()
        power.onChange = { [self] in updatePause() }
        screens.onChange = { [self] in displaysChanged() }
        screens.onLayout = { [self] in wallpaper.sync($0) }
        rotator.load = { [self] path, done in load(path, pixelArt: true, done: done) }
        rotator.show = { [self] fx in
            if transition == nil { apply(fx: fx) } else { rotationFx = fx }  // after the end of it
        }
        screens.menubar = config.menubar
        wallpaper.menubar = config.menubar
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
        case ("img", 4):
            guard let key = State.key(a[2]), let fx = fxKind(a[3]) else {
                return reply(.err("bad argument"))
            }
            let path = a[1]
            if transition != nil { return reply(.ok()) }  // ignored during a transition (SPEC §17)
            load(path) { [self] err in
                if let err { return reply(.err(Daemon.message(err))) }
                if transition != nil { return reply(.ok()) }  // it started during the decode
                set(key, .img(path), fx)
                reply(.ok())
            }
        case ("rotate", 3):
            guard let key = State.key(a[2]) else { return reply(.err("bad argument")) }
            let dir = a[1]
            if transition != nil { return reply(.ok()) }
            rotator.begin(dir) { [self] err in
                if let err { return reply(.err(Daemon.message(err))) }
                if transition != nil { return reply(.ok()) }
                set(key, .dir(dir), rotator.pick())
                reply(.ok())
            }
        case ("clear", 4):
            guard let key = State.key(a[2]), let c = Target.parseColor(a[1]), let fx = fxKind(a[3]) else {
                return reply(.err("bad argument"))
            }
            if transition != nil { return reply(.ok()) }
            set(key, .color(c), fx)
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

    /// The transition of a request. `config` is the `transition` key of the config file.
    private func fxKind(_ name: String) -> FxKind? {
        name == "config" ? config.transition : FxKind(rawValue: name)
    }

    private func set(_ key: String, _ t: Target, _ fx: FxKind) {
        if key == "all" { state = ["all": t] } else { state[key] = t }
        saveState()
        apply(fx: fx)
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
    /// `pixelArt`: an image that is not pixel art is an error (SPEC §19).
    private func load(_ path: String, pixelArt: Bool = false, done: @escaping (Error?) -> Void) {
        queue.async { [self] in
            let result = Result { () throws -> Player in
                let (hash, cache) = try Decoder.load(path: path, pixelArt: pixelArt)
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

    /// The first file of a rotation, at a restore.
    private func ensureRotation(_ dir: String) {
        guard loading.insert("dir " + dir).inserted else { return }
        rotator.begin(dir) { [self] err in
            loading.remove("dir " + dir)
            if let err {
                logger.error("rotate \(dir, privacy: .public): \(Daemon.message(err), privacy: .public)")
            } else {
                apply()
            }
        }
    }

    private func target(_ s: Screen) -> Target {
        state[String(s.id)] ?? state["all"] ?? .color(0)
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
    /// `fx`: show the change with this transition (SPEC §17). A restore ends a transition that runs.
    private func apply(fx: FxKind = .disabled) {
        rotationFx = nil  // this call shows the files of the rotations
        transition?.end()
        rotator.keep(Set(state.values.compactMap { if case .dir(let d) = $0 { return d } else { return nil } }))
        let t = Transition(fx)
        var windows: [(window: NSWindow, display: CGDirectDisplayID)] = []
        for s in screens.all.values {
            t?.before(s)
            var changed = false, file: String?
            switch target(s) {
            case .color(let c): changed = screens.show(s, color: c)
            case .img(let path): file = path
            case .dir(let dir):
                file = rotator.file(dir)
                if file == nil { ensureRotation(dir) }
            }
            if let file {
                if let p = players[file] { changed = screens.show(s, player: p) } else { ensureLoaded(file) }
            }
            t?.after(s, changed: changed)
            if changed { windows.append((s.window, s.id)) }
        }
        // Keep the next files of the rotations: `show` comes after all of them load.
        let used = Set(screens.all.values.compactMap { $0.player.map(ObjectIdentifier.init) })
        let next = rotator.files
        players = players.filter { used.contains(ObjectIdentifier($0.value)) || next.contains($0.key) }
        if let t, t.start(onEnd: { [self] in transitionEnded() }) {
            transition = t
            fxWindows = windows
        }
        updatePause()
    }

    private func transitionEnded() {
        transition = nil
        fxWindows = []
        if let fx = rotationFx { apply(fx: fx) }
    }

    private func displaysChanged() {
        for s in screens.all.values { s.player?.restoreInvariant() }
        apply()
    }

    private func updatePause() {
        // A transition does not pause: it ends when no screen of it can show it.
        if let t = transition, !power.reasons(windows: fxWindows).isEmpty { t.end() }
        var seen = Set<ObjectIdentifier>()
        for s in screens.all.values {
            guard let p = s.player, seen.insert(ObjectIdentifier(p)).inserted else { continue }
            p.setRunning(power.reasons(windows: screens.windows(of: p)).isEmpty)
        }
        // The clock of the rotations stops when no screen can show them.
        let rotating = screens.all.values.filter { if case .dir = target($0) { return true } else { return false } }
        rotator.setRunning(!rotating.isEmpty && power.reasons(windows: rotating.map { ($0.window, $0.id) }).isEmpty)
    }

    // MARK: State file

    private func saveState() {
        let text = state.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.line)\n" }.joined()
        do {
            try FileManager.default.createDirectory(at: Paths.supportDir, withIntermediateDirectories: true)
            try text.write(to: State.url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("save state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
