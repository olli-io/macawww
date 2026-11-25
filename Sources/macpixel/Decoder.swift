import Compression
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

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

    func finish(loopCount: Int, pixelArt: Bool = false) throws {
        guard count > 0 else { throw MCWError.decode("no frames") }
        try writer.finish(width: width, height: height, loopCount: loopCount, pixelArt: pixelArt)
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

    /// SHA-256 of the file bytes, in hex (SPEC §6 step 1). The name of the cache file.
    static func hash(path: String) throws -> String {
        try autoreleasepool {
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Returns a valid cache file for `path`. Decodes in a child process if needed.
    /// `pixelArt`: throw `notPixelArt` for an image that is not pixel art (SPEC §19).
    /// Call on a background queue.
    static func load(path: String, pixelArt: Bool = false) throws -> (hash: String, cache: CacheFile) {
        let hash = try hash(path: path)
        let dst = Cache.url(hash: hash)
        if FileManager.default.fileExists(atPath: dst.path) {
            if let c = try? CacheFile(url: dst) { return (hash, try check(c, pixelArt: pixelArt)) }
            try? FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.createDirectory(at: Cache.dir, withIntermediateDirectories: true)
        if var text = Child.run(["decode", path, dst.path] + (pixelArt ? [pixelArtFlag] : [])) {
            if text == MCWError.notPixelArt.description { throw MCWError.notPixelArt }
            if text.hasPrefix("decode: ") { text.removeFirst(8) }  // the child prints an MCWError
            throw MCWError.decode(text)
        }
        return (hash, try CacheFile(url: dst))
    }

    /// The argument of the `decode` child for `pixelArt`.
    static let pixelArtFlag = "--pixel-art"

    /// `c`, or `notPixelArt` when the caller wants only pixel art and `c` is not.
    static func check(_ c: CacheFile, pixelArt: Bool) throws -> CacheFile {
        if pixelArt && !c.pixelArt { throw MCWError.notPixelArt }
        return c
    }

    /// An image file, opened with ImageIO. `count` = the number of frames that macpixel shows.
    struct Source {
        let src: CGImageSource
        let path: String
        let animated: Bool
        let count: Int

        init(url: URL) throws {
            let opts = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else {
                throw MCWError.decode("cannot read \(url.path)")
            }
            let total = CGImageSourceGetCount(src)
            guard total > 0 else { throw MCWError.decode("no image in \(url.path)") }
            self.src = src
            path = url.path
            animated = total > 1 && animatedTypes.contains(CGImageSourceGetType(src) as String? ?? "")
            count = animated ? total : 1
        }

        func image(_ i: Int) throws -> CGImage {
            // Still images: apply EXIF orientation. Thumbnails never scale up.
            let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceShouldCache: false,
                                          kCGImageSourceThumbnailMaxPixelSize: Cache.maxSide]
            let img = animated
                ? CGImageSourceCreateImageAtIndex(src, i, [kCGImageSourceShouldCache: false] as CFDictionary)
                : CGImageSourceCreateThumbnailAtIndex(src, 0, thumb as CFDictionary)
            guard let img else { throw MCWError.decode("cannot decode frame \(i) of \(path)") }
            return img
        }
    }

    /// `pixelArt`: stop with `notPixelArt` when the integer upscale is 1. No cache file then.
    static func decode(url: URL, to dst: URL, pixelArt: Bool = false) throws {
        let source = try Source(url: url)
        let src = source.src, animated = source.animated
        var first: CGImage? = try source.image(0)
        let w = first?.width ?? 0, h = first?.height ?? 0
        guard (1...Cache.maxSide).contains(w), (1...Cache.maxSide).contains(h) else {
            throw MCWError.decode("image size \(w)x\(h) not supported")
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)

        // Integer upscale (SPEC §6 step 5): draw at the source size into `stage`, store 1 pixel per block.
        var stage: UnsafeMutableRawPointer? = calloc(w * h * 4, 1)
        defer { free(stage) }
        var stageCtx = stage.flatMap { FrameEncoder.context($0, w, h) }
        guard let probe = stage, let ctx = stageCtx, let img0 = first else {
            throw MCWError.decode("cannot create bitmap context")
        }
        ctx.draw(img0, in: rect)
        var n = Upscale.factor(probe, width: w, height: h)

        while true {
            if pixelArt && n == 1 { throw MCWError.notPixelArt }
            if n == 1 {  // no upscale: draw straight into the encoder
                stageCtx = nil
                free(stage)
                stage = nil
            }
            let enc = try FrameEncoder(width: w / n, height: h / n, dst: dst)
            var smaller = 0
            for i in 0..<source.count where smaller == 0 {
                try autoreleasepool {
                    let img = try first ?? source.image(i)
                    first = nil
                    if let stage, let stageCtx {
                        stageCtx.draw(img, in: rect)
                        guard Upscale.holds(stage, width: w, height: h, n: n) else {
                            // A later frame has smaller blocks: start again with the smaller factor.
                            smaller = Upscale.factor(stage, width: w, height: h, limit: n)
                            return
                        }
                        Upscale.shrink(stage, width: w, height: h, n: n, to: enc.buffer)
                    } else {
                        enc.context.draw(img, in: rect)
                    }
                    try enc.commit(delayMs: animated ? delayMs(frameDelay(src, i)) : 0)
                }
            }
            if smaller == 0 { return try enc.finish(loopCount: animated ? loopCount(src) : 0, pixelArt: n > 1) }
            n = smaller
        }
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
