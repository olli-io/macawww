import CoreGraphics
import Foundation
import ImageIO
import IOSurface
@testable import macpixel

/// Deterministic PRNG.
final class LCG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    func next() -> UInt64 {
        s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return s >> 33
    }
    func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
}

enum Fixture {
    static func tmpURL(_ ext: String = "mcw") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    /// `count` frames. Each frame differs from the one before it.
    /// The change kinds rotate: big (full frame), small spots, many spots, tile grid.
    static func frames(w: Int, h: Int, count: Int, seed: UInt64 = 1) -> [[UInt8]] {
        let rng = LCG(seed)
        var f = (0..<w * h * 4).map { _ in rng.byte() }
        var out = [f]
        for i in 1..<max(1, count) {
            switch i % 4 {
            case 0:
                for j in 0..<(f.count * 3 / 4) { f[j] = rng.byte() }
                f[0] &+= 1
            case 1:
                for _ in 0..<3 { f[(rng.int(h) * w + rng.int(w)) * 4 + 1] &+= 1 }
            case 2:
                for _ in 0..<40 { f[(rng.int(h) * w + rng.int(w)) * 4 + 2] &+= 1 }
            default:
                for y in stride(from: 0, to: h, by: 64) {
                    for x in stride(from: 0, to: w, by: 64) { f[(y * w + x) * 4 + 3] &+= 7 }
                }
            }
            out.append(f)
        }
        return out
    }

    static func encode(_ frames: [[UInt8]], w: Int, h: Int, delays: [Int]? = nil,
                       loop: Int = 0) throws -> CacheFile {
        let url = tmpURL()
        let enc = try FrameEncoder(width: w, height: h, dst: url)
        for (i, f) in frames.enumerated() {
            f.withUnsafeBytes { _ = memcpy(enc.buffer, $0.baseAddress!, $0.count) }
            try enc.commit(delayMs: delays?[i] ?? 40)
        }
        try enc.finish(loopCount: loop)
        return try CacheFile(url: url)
    }

    /// Applies each diff in order on one buffer. Returns the frame after each step.
    static func replay(_ c: CacheFile) -> [[UInt8]] {
        let w = c.width, h = c.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let scratch = malloc(Blit.scratchSize)!, tmp = malloc(w * h * 4)!
        defer { free(scratch); free(tmp) }
        var out: [[UInt8]] = []
        for k in 0..<c.frameCount {
            buf.withUnsafeMutableBytes {
                Blit.apply(c, frame: k, base: $0.baseAddress!, stride: w * 4, scratch: scratch, tmp: tmp)
            }
            out.append(buf)
        }
        return out
    }

    static func read(_ s: IOSurfaceRef, w: Int, h: Int) -> [UInt8] {
        IOSurfaceLock(s, .readOnly, nil)
        defer { IOSurfaceUnlock(s, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(s), stride = IOSurfaceGetBytesPerRow(s)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { o in
            for y in 0..<h { memcpy(o.baseAddress! + y * w * 4, base + y * stride, w * 4) }
        }
        return out
    }

    /// Renders a CGImage the same way the decoder does.
    static func render(_ img: CGImage, w: Int, h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes {
            let ctx = FrameEncoder.context($0.baseAddress!, w, h)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return out
    }

    /// Point sample of a rendered frame, as the decoder stores it.
    static func shrink(_ px: [UInt8], w: Int, h: Int, n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (w / n) * (h / n) * 4)
        px.withUnsafeBytes { s in out.withUnsafeMutableBytes { d in
            Upscale.shrink(s.baseAddress!, width: w, height: h, n: n, to: d.baseAddress!)
        } }
        return out
    }

    /// Each pixel of `px` (w × h) becomes an n×n block.
    static func upscale(_ px: [UInt8], w: Int, h: Int, n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: px.count * n * n)
        for y in 0..<h * n {
            for x in 0..<w * n {
                let s = ((y / n) * w + x / n) * 4, d = (y * w * n + x) * 4
                for c in 0..<4 { out[d + c] = px[s + c] }
            }
        }
        return out
    }

    /// GIF with a moving square. `same[i]` true: frame i equals frame i-1.
    /// `blank0`: frame 0 has no square (one colour).
    static func gif(w: Int, h: Int, delays: [Double], same: [Bool], blank0: Bool = false) -> URL {
        let url = tmpURL("gif")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, delays.count, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var pos = 0
        for (i, d) in delays.enumerated() {
            if !same[i] { pos += 1 }
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(red: 1, green: 0.9, blue: 0.1, alpha: 1)
            if !(blank0 && i == 0) { ctx.fill(CGRect(x: pos * 6, y: 4, width: 8, height: 8)) }
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: d]] as CFDictionary
            CGImageDestinationAddImage(dest, ctx.makeImage()!, props)
        }
        CGImageDestinationFinalize(dest)
        return url
    }
}
