import Compression
import CoreGraphics
import Foundation
import IOSurface
import QuartzCore

/// Decompresses the rects of one frame into a pixel buffer.
enum Blit {
    static let scratchSize = max(1, compression_decode_scratch_buffer_size(COMPRESSION_LZ4_RAW))

    /// A rect decodes straight into the destination when its rows are contiguous there.
    static func direct(_ w: Int, width: Int, stride: Int) -> Bool { w == width && stride == w * 4 }

    /// Bytes of `tmp` that `apply` needs for this cache and stride.
    static func tmpSize(_ c: CacheFile, stride: Int) -> Int {
        c.rects.reduce(0) { direct($1.rect.w, width: c.width, stride: stride) ? $0 : max($0, $1.rect.area * 4) }
    }

    /// No allocation. `scratch` holds `scratchSize` bytes, `tmp` holds `tmpSize` bytes.
    static func apply(_ c: CacheFile, frame: Int, base: UnsafeMutableRawPointer, stride: Int,
                      scratch: UnsafeMutableRawPointer, tmp: UnsafeMutableRawPointer?) {
        let f = c.frames[frame]
        var i = f.first
        let end = f.first + f.count
        while i < end {
            let e = c.rects[i]
            i += 1
            let r = e.rect, rb = r.w * 4, n = rb * r.h
            let src = (c.base + e.offset).assumingMemoryBound(to: UInt8.self)
            let dst = base + r.y * stride + r.x * 4
            if direct(r.w, width: c.width, stride: stride) {
                _ = compression_decode_buffer(dst.assumingMemoryBound(to: UInt8.self), n, src, e.size,
                                              scratch, COMPRESSION_LZ4_RAW)
            } else if let tmp {
                _ = compression_decode_buffer(tmp.assumingMemoryBound(to: UInt8.self), n, src, e.size,
                                              scratch, COMPRESSION_LZ4_RAW)
                var row = 0
                while row < r.h {
                    memcpy(dst + row * stride, tmp + row * rb, rb)
                    row += 1
                }
            }
        }
    }

    /// Copies the rects of diff `frame` from `src` to `dst`. Both have `stride`. No allocation.
    static func copy(_ c: CacheFile, frame: Int, from src: UnsafeRawPointer, to dst: UnsafeMutableRawPointer,
                     stride: Int) {
        let f = c.frames[frame]
        var i = f.first
        let end = f.first + f.count
        while i < end {
            let r = c.rects[i].rect
            i += 1
            let off = r.y * stride + r.x * 4, rb = r.w * 4
            if r.w == c.width {
                memcpy(dst + off, src + off, stride * (r.h - 1) + rb)
            } else {
                var row = 0
                while row < r.h {
                    memcpy(dst + off + row * stride, src + off + row * stride, rb)
                    row += 1
                }
            }
        }
    }
}

/// IOSurface double buffer and frame timer for one file (SPEC §8).
/// All methods on the main thread, except `init`.
final class Player {
    let key: String  // SHA-256 of the file
    let path: String
    let cacheURL: String
    let width: Int
    let height: Int
    let frameCount: Int
    /// Stored at 1× by the decoder: screens show it at an integer scale (SPEC §5).
    let pixelArt: Bool
    private let loopCount: Int
    private var cache: CacheFile?
    private(set) var front: IOSurfaceRef
    private var back: IOSurfaceRef?
    private var scratch: UnsafeMutableRawPointer?
    private var tmp: UnsafeMutableRawPointer?
    private(set) var layers: [CALayer] = []
    private var timer: DispatchSourceTimer?
    private var next = 1     // frame of the next tick
    private var synced = false  // invariant: back holds frame next-2
    private var loops = 0
    private(set) var running = false
    private(set) var isFinished = false
    var isStatic: Bool { frameCount == 1 }

    init(key: String, path: String, cache: CacheFile) throws {
        self.key = key
        self.path = path
        cacheURL = cache.url.path
        width = cache.width
        height = cache.height
        frameCount = cache.frameCount
        loopCount = cache.loopCount
        pixelArt = cache.pixelArt
        guard let f = Player.surface(width, height) else { throw MCWError.io("IOSurface create failed") }
        front = f
        if frameCount > 1 {
            guard let b = Player.surface(width, height) else { throw MCWError.io("IOSurface create failed") }
            back = b
        }
        let stride = IOSurfaceGetBytesPerRow(f)
        let s = malloc(Blit.scratchSize)!
        let t = Blit.tmpSize(cache, stride: stride)
        scratch = s
        tmp = t > 0 ? malloc(t) : nil
        IOSurfaceLock(f, [], nil)
        Blit.apply(cache, frame: 0, base: IOSurfaceGetBaseAddress(f), stride: stride, scratch: s, tmp: tmp)
        IOSurfaceUnlock(f, [], nil)
        if frameCount > 1 {
            self.cache = cache
        } else {
            // Static: the pixels live in `front` only. Drop the mmap and buffers.
            free(scratch); scratch = nil
            free(tmp); tmp = nil
        }
    }

    deinit {
        timer?.cancel()
        free(scratch)
        free(tmp)
    }

    /// Delay before a retry when `back` cannot lock.
    private static let retryMs = 16

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList()

    static func surface(_ w: Int, _ h: Int) -> IOSurfaceRef? {
        let props: [CFString: Any] = [
            kIOSurfaceWidth: w,
            kIOSurfaceHeight: h,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, w * 4),
            kIOSurfacePixelFormat: UInt32(0x4247_5241),  // 'BGRA'
        ]
        guard let s = IOSurfaceCreate(props as CFDictionary) else { return nil }
        if let cs = colorSpace { IOSurfaceSetValue(s, "IOSurfaceColorSpace" as CFString, cs) }
        return s
    }

    func attach(_ layer: CALayer) {
        layers.append(layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = nil
        layer.contents = front
        CATransaction.commit()
    }

    func detach(_ layer: CALayer) {
        layers.removeAll { $0 === layer }
        if layers.isEmpty { setRunning(false) }
    }

    /// Next tick copies `front` into `back` and applies one diff (SPEC §8).
    func restoreInvariant() { synced = false }

    func setRunning(_ on: Bool) {
        guard frameCount > 1, !isFinished, on != running else { return }
        running = on
        timer?.cancel()
        timer = nil
        // Paused: `back` needs no content, because the first tick after resume copies `front`.
        // Volatile lets the kernel take the pages back.
        if let b = back { Player.setVolatile(b, !on) }
        guard on, let cache else { return }
        synced = false
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in self?.step() }
        timer = t
        schedule(cache.frames[(next + frameCount - 1) % frameCount].delayMs)
        t.activate()
    }

    private static func setVolatile(_ s: IOSurfaceRef, _ v: Bool) {
        let state: IOSurfacePurgeabilityState = v ? .purgeableVolatile : []
        _ = IOSurfaceSetPurgeable(s, state.rawValue, nil)
    }

    private func schedule(_ ms: Int) {
        timer?.schedule(deadline: .now() + .milliseconds(ms), leeway: .milliseconds(max(1, ms / 10)))
    }

    /// One tick: show frame `next`. No allocation, no logging.
    func step() {
        guard let cache, let b = back, let scratch, !isFinished else { return }
        let k = next
        let stride = IOSurfaceGetBytesPerRow(b)
        guard IOSurfaceLock(b, [], nil) == 0 else { return schedule(Player.retryMs) }
        let base = IOSurfaceGetBaseAddress(b)
        if !cache.frames[k].full {
            // back := front (frame k-1). Synced: back holds k-2, so only the rects of diff k-1 differ.
            IOSurfaceLock(front, .readOnly, nil)
            let src = UnsafeRawPointer(IOSurfaceGetBaseAddress(front))
            if synced {
                Blit.copy(cache, frame: (k + frameCount - 1) % frameCount, from: src, to: base, stride: stride)
            } else {
                memcpy(base, src, stride * height)
            }
            IOSurfaceUnlock(front, .readOnly, nil)
        }
        Blit.apply(cache, frame: k, base: base, stride: stride, scratch: scratch, tmp: tmp)
        IOSurfaceUnlock(b, [], nil)
        synced = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in layers { l.contents = b }
        CATransaction.commit()
        back = front
        front = b

        next = k + 1 == frameCount ? 0 : k + 1
        if next == 0 {
            loops += 1
            if loopCount > 0 && loops >= loopCount { return finish() }
        }
        schedule(cache.frames[k].delayMs)
    }

    /// Last loop done: keep `front` on screen, release all else (as a static image).
    private func finish() {
        isFinished = true
        running = false
        timer?.cancel()
        timer = nil
        back = nil
        cache = nil
        free(scratch); scratch = nil
        free(tmp); tmp = nil
    }
}
