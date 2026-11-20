import Compression
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Tile diff and rect merge (SPEC §6 steps 5–7).
enum Diff {
    static let tile = 32
    static let maxRects = 8

    /// Marks changed tiles in `grid` (cols × rows). Returns the count of changed tiles.
    static func tiles(prev: UnsafeRawPointer, cur: UnsafeRawPointer, width: Int, height: Int,
                      grid: inout [Bool]) -> Int {
        let cols = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        let stride = width * 4
        var dirty = 0
        for ty in 0..<rows {
            let y0 = ty * tile, y1 = min(y0 + tile, height)
            for tx in 0..<cols {
                let x0 = tx * tile * 4, n = (min((tx + 1) * tile, width) - tx * tile) * 4
                var d = false
                var y = y0
                while y < y1 {
                    if memcmp(prev + y * stride + x0, cur + y * stride + x0, n) != 0 { d = true; break }
                    y += 1
                }
                grid[ty * cols + tx] = d
                if d { dirty += 1 }
            }
        }
        return dirty
    }

    /// Changed tiles → at most `maxRects` pixel rects.
    static func merge(grid: [Bool], width: Int, height: Int) -> [Rect] {
        let cols = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        // Row runs, then vertical merge of runs with the same x and width.
        var rects: [Rect] = []
        var open: [Int: Int] = [:]
        for ty in 0..<rows {
            var next: [Int: Int] = [:]
            var tx = 0
            while tx < cols {
                guard grid[ty * cols + tx] else { tx += 1; continue }
                let s = tx
                while tx < cols && grid[ty * cols + tx] { tx += 1 }
                let key = s << 16 | (tx - s)
                if let i = open[key] {
                    rects[i].h += 1
                    next[key] = i
                } else {
                    rects.append(Rect(x: s, y: ty, w: tx - s, h: 1))
                    next[key] = rects.count - 1
                }
            }
            open = next
        }
        // Too many rects for the pair merge: one bounding box per band of tile rows.
        if rects.count > 64 {
            rects = []
            let bh = (rows + 31) / 32
            var by = 0
            while by < rows {
                let y1 = min(by + bh, rows)
                var box: Rect?
                for ty in by..<y1 {
                    for tx in 0..<cols where grid[ty * cols + tx] {
                        let t = Rect(x: tx, y: ty, w: 1, h: 1)
                        box = box?.union(t) ?? t
                    }
                }
                if let box { rects.append(box) }
                by = y1
            }
        }
        // Merge the pair with the smallest bounding box until ≤ maxRects.
        while rects.count > maxRects {
            var bi = 0, bj = 1, best = Int.max
            for i in 0..<rects.count {
                for j in (i + 1)..<rects.count {
                    let a = rects[i].union(rects[j]).area
                    if a < best { best = a; bi = i; bj = j }
                }
            }
            rects[bi] = rects[bi].union(rects[bj])
            rects.remove(at: bj)
        }
        return rects.map {
            Rect(x: $0.x * tile, y: $0.y * tile,
                 w: min(($0.x + $0.w) * tile, width) - $0.x * tile,
                 h: min(($0.y + $0.h) * tile, height) - $0.y * tile)
        }
    }
}

/// Takes full frames one at a time, writes diffs + LZ4 to a cache file.
/// Holds the current and the previous frame only.
final class FrameEncoder {
    let width: Int
    let height: Int
    private var prev: UnsafeMutableRawPointer
    private var cur: UnsafeMutableRawPointer
    private var prevCtx: CGContext
    private var curCtx: CGContext
    private let pack: UnsafeMutableRawPointer
    private let out: UnsafeMutableRawPointer
    private let outCap: Int
    private let scratch: UnsafeMutableRawPointer
    private var grid: [Bool]
    private let writer: CacheWriter
    private(set) var count = 0

    /// The buffer for the next frame (BGRA premultiplied, stride = width × 4).
    var buffer: UnsafeMutableRawPointer { cur }
    /// A bitmap context that draws into `buffer`.
    var context: CGContext { curCtx }

    init(width: Int, height: Int, dst: URL) throws {
        guard (1...Cache.maxSide).contains(width), (1...Cache.maxSide).contains(height) else {
            throw MCWError.decode("image size \(width)x\(height) not supported")
        }
        let writer = try CacheWriter(dst: dst)
        let n = width * height * 4
        // calloc: pages stay unmapped until touched.
        let p = calloc(n, 1)!, c = calloc(n, 1)!
        guard let a = FrameEncoder.context(p, width, height), let b = FrameEncoder.context(c, width, height) else {
            free(p)
            free(c)
            throw MCWError.decode("cannot create bitmap context")
        }
        self.writer = writer
        self.width = width
        self.height = height
        prev = p
        cur = c
        prevCtx = a
        curCtx = b
        pack = calloc(n, 1)!
        // compression_encode_buffer (LZ4_RAW) gives 0 if the destination is < 128 bytes.
        outCap = n + n / 255 + 128
        out = calloc(outCap, 1)!
        scratch = calloc(max(1, compression_encode_scratch_buffer_size(COMPRESSION_LZ4_RAW)), 1)!
        grid = [Bool](repeating: false, count: ((width + 31) / 32) * ((height + 31) / 32))
    }

    deinit {
        for p in [prev, cur, pack, out, scratch] { free(p) }
    }

    static func context(_ data: UnsafeMutableRawPointer, _ w: Int, _ h: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: info)
        ctx?.setBlendMode(.copy)
        ctx?.interpolationQuality = .none
        return ctx
    }

    /// Stores `buffer` as the next frame.
    func commit(delayMs: Int) throws {
        let full = Rect(x: 0, y: 0, w: width, h: height)
        var rects = [full]
        if count > 0 {
            if Diff.tiles(prev: prev, cur: cur, width: width, height: height, grid: &grid) == 0 {
                writer.addDelay(delayMs)  // identical to the previous frame
                return
            }
            rects = Diff.merge(grid: grid, width: width, height: height)
            if rects.reduce(0, { $0 + $1.area }) * 2 > full.area { rects = [full] }
        }
        writer.beginFrame(delayMs: delayMs, rectCount: rects.count)
        for r in rects { try store(r) }
        swap(&prev, &cur)
        swap(&prevCtx, &curCtx)
        count += 1
    }

    func finish(loopCount: Int) throws {
        guard count > 0 else { throw MCWError.decode("no frames") }
        try writer.finish(width: width, height: height, loopCount: loopCount)
    }

    private func store(_ r: Rect) throws {
        let rb = r.w * 4, stride = width * 4
        var src = UnsafeRawPointer(cur + r.y * stride)
        if r.w != width {
            for row in 0..<r.h { memcpy(pack + row * rb, cur + (r.y + row) * stride + r.x * 4, rb) }
            src = UnsafeRawPointer(pack)
        }
        let size = compression_encode_buffer(out.assumingMemoryBound(to: UInt8.self), outCap,
                                             src.assumingMemoryBound(to: UInt8.self), rb * r.h,
                                             scratch, COMPRESSION_LZ4_RAW)
        guard size > 0 else { throw MCWError.decode("lz4 encode failed") }
        try writer.addRect(r, out, size)
    }
}

/// ImageIO → FrameEncoder → cache file (SPEC §6).
enum Decoder {
    static let animatedTypes: Set<String> = ["com.compuserve.gif", "public.png", "org.webmproject.webp"]

    /// SPEC §6 step 3: a delay < 20 ms becomes 100 ms.
    static func delayMs(_ seconds: Double) -> Int {
        (seconds.isNaN || seconds < 0.02) ? 100 : Int((seconds * 1000).rounded())
    }

    /// Returns a valid cache file for `path`. Decodes if needed. Call on a background queue.
    static func load(path: String) throws -> (hash: String, cache: CacheFile) {
        let url = URL(fileURLWithPath: path)
        let hash = try autoreleasepool {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let dst = Cache.url(hash: hash)
        if FileManager.default.fileExists(atPath: dst.path) {
            if let c = try? CacheFile(url: dst) { return (hash, c) }
            try? FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.createDirectory(at: Cache.dir, withIntermediateDirectories: true)
        try decode(url: url, to: dst)
        return (hash, try CacheFile(url: dst))
    }

    static func decode(url: URL, to dst: URL) throws {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else {
            throw MCWError.decode("cannot read \(url.path)")
        }
        let total = CGImageSourceGetCount(src)
        guard total > 0 else { throw MCWError.decode("no image in \(url.path)") }
        let type = CGImageSourceGetType(src) as String? ?? ""
        let animated = total > 1 && animatedTypes.contains(type)
        // Still images: apply EXIF orientation. Thumbnails never scale up.
        let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCache: false,
                                      kCGImageSourceThumbnailMaxPixelSize: Cache.maxSide]
        var first = animated ? CGImageSourceCreateImageAtIndex(src, 0, opts)
                             : CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary)
        guard let size = first.map({ ($0.width, $0.height) }) else {
            throw MCWError.decode("cannot decode \(url.path)")
        }
        let (w, h) = size
        let enc = try FrameEncoder(width: w, height: h, dst: dst)
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        for i in 0..<(animated ? total : 1) {
            try autoreleasepool {
                let img = i == 0 ? first : CGImageSourceCreateImageAtIndex(src, i, opts)
                first = nil
                guard let img else { throw MCWError.decode("cannot decode frame \(i)") }
                enc.context.draw(img, in: rect)
                try enc.commit(delayMs: animated ? delayMs(frameDelay(src, i)) : 0)
            }
        }
        try enc.finish(loopCount: animated ? loopCount(src) : 0)
    }

    private static let delayKeys: [(CFString, CFString, CFString)] = [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
    ]

    static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0 }
        for (dict, unclamped, clamped) in delayKeys {
            guard let d = p[dict] as? [CFString: Any] else { continue }
            if let v = (d[unclamped] as? NSNumber)?.doubleValue, v > 0 { return v }
            return (d[clamped] as? NSNumber)?.doubleValue ?? 0
        }
        return 0
    }

    static func loopCount(_ src: CGImageSource) -> Int {
        guard let p = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] else { return 0 }
        let keys = [(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
                    (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
                    (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount)]
        for (dict, key) in keys {
            if let n = ((p[dict] as? [CFString: Any])?[key] as? NSNumber)?.intValue { return max(0, n) }
        }
        return 0
    }
}
