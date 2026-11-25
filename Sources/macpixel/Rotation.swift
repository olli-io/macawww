import Foundation

/// Loads a file as pixel art and calls back on the main thread. nil: the file loaded.
typealias PixelArtLoader = (String, @escaping (Error?) -> Void) -> Void

/// A rotation through the pixel art of one directory (SPEC §19). Main thread only.
final class Rotation {
    let dir: String
    private let random: Bool
    /// The file on screen. nil before the first file loads.
    private(set) var current: String?
    /// random: the files of this pass that did not show yet.
    private var pass: [String] = []
    /// Files that are not pixel art or that did not load. They are not tried again.
    private(set) var rejected = Set<String>()

    init(dir: String, random: Bool) {
        self.dir = dir
        self.random = random
    }

    /// The image files of the directory, in Finder name order, without the rejected files.
    private func files() -> [String] {
        Folder.images(in: URL(fileURLWithPath: dir, isDirectory: true)).map(\.path).filter { !rejected.contains($0) }
    }

    /// The next file to try after `after`. nil: no file to try.
    /// The directory is read again each time, so new and removed files have an effect.
    func candidate(after: String?) -> String? {
        let all = files()
        guard !all.isEmpty else { return nil }
        if random {
            let set = Set(all)
            pass.removeAll { !set.contains($0) }
            if pass.isEmpty {
                pass = all.shuffled()
                // A new pass does not start with the file on screen.
                if pass.count > 1, pass[0] == current { pass.swapAt(0, pass.count - 1) }
            }
            return pass[0]
        }
        guard let after else { return all[0] }
        let name = (after as NSString).lastPathComponent
        return all.first { Folder.before(name, ($0 as NSString).lastPathComponent) } ?? all[0]
    }

    func accept(_ path: String) {
        current = path
        pass.removeAll { $0 == path }
    }

    func reject(_ path: String) {
        rejected.insert(path)
        pass.removeAll { $0 == path }
    }

    /// Loads the next pixel art file. Tries the files in order until one loads.
    /// On error the current file does not change.
    func advance(load: @escaping PixelArtLoader, done: @escaping (Error?) -> Void) {
        attempt(candidate(after: current), load, done)
    }

    private func attempt(_ path: String?, _ load: @escaping PixelArtLoader, _ done: @escaping (Error?) -> Void) {
        guard let path else { return done(MCWError.noPixelArt(dir)) }
        load(path) { [self] err in
            if err == nil {
                accept(path)
                return done(nil)
            }
            reject(path)
            attempt(candidate(after: path), load, done)
        }
    }
}

/// The rotations of a process (SPEC §19): one for each directory in use, and one clock
/// for all. Main thread only. The daemon and the screensaver supply `load` and `show`.
final class Rotator {
    /// Seconds between two files.
    let interval: Int
    let random: Bool
    let kinds: [FxKind]
    var load: PixelArtLoader = { $1(nil) }
    /// Shows the new files of the rotations with this transition.
    var show: (FxKind) -> Void = { _ in }
    private var all: [String: Rotation] = [:]
    /// The callers of `begin` for each directory whose first file loads.
    private var waiting: [String: [(Error?) -> Void]] = [:]
    private var timer: DispatchSourceTimer?
    private var deadline: DispatchTime?
    /// Nanoseconds to the next step, while the clock is stopped.
    private var left: UInt64
    private var running = false
    private var stepping = false

    init(interval: Int, random: Bool, kinds: [FxKind]) {
        self.interval = interval
        self.random = random
        self.kinds = kinds
        left = UInt64(interval) * 1_000_000_000
    }

    /// The file on screen for `dir`. nil before its first file loads.
    func file(_ dir: String) -> String? { all[dir]?.current }

    /// The files on screen of all rotations.
    var files: Set<String> { Set(all.values.compactMap(\.current)) }

    /// A transition of the list.
    func pick() -> FxKind { kinds.randomElement() ?? .disabled }

    /// Keeps the rotations of `dirs` only.
    func keep(_ dirs: Set<String>) {
        all = all.filter { dirs.contains($0.key) || waiting[$0.key] != nil }
    }

    /// Loads the first file of `dir`. A directory that already rotates keeps its file.
    func begin(_ dir: String, done: @escaping (Error?) -> Void) {
        if all[dir]?.current != nil { return done(nil) }
        if waiting[dir] != nil { return waiting[dir]!.append(done) }
        waiting[dir] = [done]
        let r = all[dir] ?? Rotation(dir: dir, random: random)
        all[dir] = r
        r.advance(load: load) { [self] err in
            if err != nil, r.current == nil, all[dir] === r { all[dir] = nil }
            for d in waiting.removeValue(forKey: dir) ?? [] { d(err) }
        }
    }

    /// The clock runs only while a screen that shows a rotation is not paused. A stopped
    /// clock keeps the time that remains.
    func setRunning(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on {
            if !stepping { schedule(left) }
            return
        }
        if let deadline {
            let now = DispatchTime.now().uptimeNanoseconds
            left = deadline.uptimeNanoseconds > now ? deadline.uptimeNanoseconds - now : 0
        }
        cancel()
    }

    private func cancel() {
        timer?.cancel()
        timer = nil
        deadline = nil
    }

    private func schedule(_ ns: UInt64) {
        cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in self?.step() }
        let d = DispatchTime.now() + .nanoseconds(Int(min(ns, UInt64(Int.max))))
        t.schedule(deadline: d, leeway: .seconds(1))
        deadline = d
        timer = t
        t.activate()
    }

    /// Advances all rotations, then shows the new files with one transition.
    /// A rotation that cannot advance keeps its file.
    private func step() {
        cancel()
        left = UInt64(interval) * 1_000_000_000
        let list = all.values.filter { $0.current != nil && waiting[$0.dir] == nil }
        guard !list.isEmpty else {
            if running { schedule(left) }
            return
        }
        stepping = true
        var pending = list.count
        for r in list {
            r.advance(load: load) { [self] _ in
                pending -= 1
                guard pending == 0 else { return }
                stepping = false
                show(pick())
                if running { schedule(left) }
            }
        }
    }
}
