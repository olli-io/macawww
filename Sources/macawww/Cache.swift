import Foundation

enum MCWError: Error, CustomStringConvertible {
    case io(String)
    case bad(String)
    case decode(String)

    var description: String {
        switch self {
        case .io(let m): return "io: \(m)"
        case .bad(let m): return "bad cache file: \(m)"
        case .decode(let m): return "decode: \(m)"
        }
    }
}

struct Rect: Equatable {
    var x: Int, y: Int, w: Int, h: Int
    var area: Int { w * h }

    func union(_ o: Rect) -> Rect {
        let x0 = min(x, o.x), y0 = min(y, o.y)
        return Rect(x: x0, y: y0, w: max(x + w, o.x + o.w) - x0, h: max(y + h, o.y + o.h) - y0)
    }
}

struct CacheRect: Equatable {
    let rect: Rect
    let offset: Int
    let size: Int
}

struct CacheFrame: Equatable {
    let delayMs: Int
    let first: Int  // index into CacheFile.rects
    let count: Int
    let full: Bool  // one rect that covers the frame
}

/// `.mcw` file format constants, paths and eviction (SPEC §7).
enum Cache {
    static let magic: UInt32 = 0x5757_434D  // bytes "MCWW"
    static let version: UInt16 = 1
    static let headerSize = 32
    static let frameEntrySize = 8
    static let rectEntrySize = 20  // 4 × u16, u64, u32
    static let maxSide = 16384

    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/macawww", isDirectory: true)
    }

    static func url(hash: String) -> URL { dir.appendingPathComponent(hash + ".mcw") }

    /// LRU by access time. `keep` holds paths that must stay.
    static func evict(maxBytes: Int, keep: Set<String>) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentAccessDateKey, .fileSizeKey]
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, date: Date, size: Int)] = urls.filter { $0.pathExtension == "mcw" }.map {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return ($0, v?.contentAccessDate ?? .distantPast, v?.fileSize ?? 0)
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        files.sort { $0.date < $1.date }
        for f in files where total > maxBytes && !keep.contains(f.url.path) {
            if (try? fm.removeItem(at: f.url)) != nil { total -= f.size }
        }
    }
}

/// Writes a `.mcw` file: temp file, fsync, rename.
final class CacheWriter {
    let dst: URL
    private let tmp: URL
    private var fd: Int32
    private var pos = 0
    private var index: [UInt8] = []
    private var frames = 0
    private var lastDelayAt = -1

    init(dst: URL) throws {
        self.dst = dst
        tmp = dst.deletingLastPathComponent()
            .appendingPathComponent(".\(dst.lastPathComponent).\(getpid()).tmp")
        fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw MCWError.io("open \(tmp.path): errno \(errno)") }
        try write([UInt8](repeating: 0, count: Cache.headerSize))
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
            unlink(tmp.path)
        }
    }

    func beginFrame(delayMs: Int, rectCount: Int) {
        lastDelayAt = index.count
        CacheWriter.put(UInt32(clamping: delayMs), &index)
        CacheWriter.put(UInt32(rectCount), &index)
        frames += 1
    }

    /// Adds `ms` to the delay of the last frame (identical-frame merge).
    func addDelay(_ ms: Int) {
        guard lastDelayAt >= 0 else { return }
        var v = 0
        for i in 0..<4 { v |= Int(index[lastDelayAt + i]) << (8 * i) }
        v = min(v + ms, Int(UInt32.max))
        for i in 0..<4 { index[lastDelayAt + i] = UInt8((v >> (8 * i)) & 0xFF) }
    }

    func addRect(_ r: Rect, _ bytes: UnsafeRawPointer, _ count: Int) throws {
        let pad = (16 - pos % 16) % 16
        if pad > 0 { try write([UInt8](repeating: 0, count: pad)) }
        let offset = pos
        try write(bytes, count)
        for v in [r.x, r.y, r.w, r.h] { CacheWriter.put(UInt16(v), &index) }
        CacheWriter.put(UInt64(offset), &index)
        CacheWriter.put(UInt32(count), &index)
    }

    func finish(width: Int, height: Int, loopCount: Int) throws {
        let indexOffset = pos
        try write(index)
        var h: [UInt8] = []
        CacheWriter.put(Cache.magic, &h)
        CacheWriter.put(Cache.version, &h)
        CacheWriter.put(UInt16(0), &h)
        CacheWriter.put(UInt32(width), &h)
        CacheWriter.put(UInt32(height), &h)
        CacheWriter.put(UInt32(frames), &h)
        CacheWriter.put(UInt32(clamping: loopCount), &h)
        CacheWriter.put(UInt64(indexOffset), &h)
        let n = h.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard n == Cache.headerSize, fsync(fd) == 0 else { throw MCWError.io("header: errno \(errno)") }
        Darwin.close(fd)
        fd = -1
        guard rename(tmp.path, dst.path) == 0 else {
            unlink(tmp.path)
            throw MCWError.io("rename: errno \(errno)")
        }
    }

    private func write(_ p: UnsafeRawPointer, _ n: Int) throws {
        var done = 0
        while done < n {
            let r = Darwin.write(fd, p + done, n - done)
            if r < 0 {
                if errno == EINTR { continue }
                throw MCWError.io("write: errno \(errno)")
            }
            done += r
        }
        pos += n
    }

    private func write(_ b: [UInt8]) throws {
        guard !b.isEmpty else { return }
        try b.withUnsafeBytes { try write($0.baseAddress!, $0.count) }
    }

    private static func put<T: FixedWidthInteger>(_ v: T, _ a: inout [UInt8]) {
        withUnsafeBytes(of: v.littleEndian) { a.append(contentsOf: $0) }
    }
}

/// Read-only mmap of a `.mcw` file. The index is parsed and checked once at open.
final class CacheFile {
    let url: URL
    let base: UnsafeRawPointer
    let length: Int
    let width: Int
    let height: Int
    let loopCount: Int
    let frames: [CacheFrame]
    let rects: [CacheRect]
    var frameCount: Int { frames.count }

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw MCWError.io("open \(url.path): errno \(errno)") }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw MCWError.io("fstat: errno \(errno)") }
        let len = Int(st.st_size)
        guard len >= Cache.headerSize else { throw MCWError.bad("truncated") }
        guard let m = mmap(nil, len, PROT_READ, MAP_PRIVATE, fd, 0), m != MAP_FAILED else {
            throw MCWError.io("mmap: errno \(errno)")
        }
        let p = UnsafeRawPointer(m)
        let r: Parsed
        do { r = try CacheFile.parse(p, len) } catch {
            munmap(m, len)
            throw error
        }
        self.url = url
        base = p
        length = len
        width = r.width
        height = r.height
        loopCount = r.loopCount
        frames = r.frames
        rects = r.rects
        // Set atime to now (UTIME_NOW = -1), keep mtime (UTIME_OMIT = -2). Used by LRU eviction.
        var ts = [timespec(tv_sec: 0, tv_nsec: -1), timespec(tv_sec: 0, tv_nsec: -2)]
        _ = futimens(fd, &ts)
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), length) }

    struct Parsed {
        var width = 0, height = 0, loopCount = 0
        var frames: [CacheFrame] = []
        var rects: [CacheRect] = []
    }

    static func parse(_ p: UnsafeRawPointer, _ len: Int) throws -> Parsed {
        func u16(_ o: Int) -> Int { Int(UInt16(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt16.self))) }
        func u32(_ o: Int) -> Int { Int(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
        func u64(_ o: Int) -> UInt64 { UInt64(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }

        guard u32(0) == Int(Cache.magic) else { throw MCWError.bad("magic") }
        guard u16(4) == Int(Cache.version) else { throw MCWError.bad("version") }
        var r = Parsed()
        r.width = u32(8)
        r.height = u32(12)
        let n = u32(16)
        r.loopCount = u32(20)
        let idx64 = u64(24)
        guard (1...Cache.maxSide).contains(r.width), (1...Cache.maxSide).contains(r.height) else {
            throw MCWError.bad("size")
        }
        guard n > 0, idx64 >= UInt64(Cache.headerSize), idx64 <= UInt64(len) else { throw MCWError.bad("index") }
        let idx = Int(idx64)
        guard n <= (len - idx) / Cache.frameEntrySize else { throw MCWError.bad("truncated index") }
        r.frames.reserveCapacity(n)
        var o = idx
        for _ in 0..<n {
            guard len - o >= Cache.frameEntrySize else { throw MCWError.bad("truncated index") }
            let delay = u32(o), count = u32(o + 4)
            o += Cache.frameEntrySize
            guard count > 0, count <= (len - o) / Cache.rectEntrySize else { throw MCWError.bad("truncated index") }
            let first = r.rects.count
            for _ in 0..<count {
                let rect = Rect(x: u16(o), y: u16(o + 2), w: u16(o + 4), h: u16(o + 6))
                let off = u64(o + 8), size = u32(o + 16)
                o += Cache.rectEntrySize
                guard rect.w > 0, rect.h > 0, rect.x + rect.w <= r.width, rect.y + rect.h <= r.height,
                      off >= UInt64(Cache.headerSize), off <= idx64, size > 0, UInt64(size) <= idx64 - off
                else { throw MCWError.bad("rect") }
                r.rects.append(CacheRect(rect: rect, offset: Int(off), size: size))
            }
            let full = count == 1 && r.rects[first].rect == Rect(x: 0, y: 0, w: r.width, h: r.height)
            r.frames.append(CacheFrame(delayMs: delay, first: first, count: count, full: full))
        }
        guard o == len else { throw MCWError.bad("trailing bytes") }
        guard r.frames[0].full else { throw MCWError.bad("frame 0 not full") }
        return r
    }
}
