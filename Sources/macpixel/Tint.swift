import CoreGraphics
import IOSurface

/// A source for the pieces of vhstape (SPEC §17): the old wallpaper in grey, or one
/// channel of that grey. It is a surface for an image and a colour for a colour.
struct Tint {
    var surface: IOSurfaceRef?
    var color: CGColor?

    /// Grey, then only the red, green or blue channel. The index is `Piece.src - 1`.
    static let masks: [UInt32] = [0xFFFF_FFFF, 0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF]

    /// One pixel (0xAARRGGBB) in grey.
    static func grey(_ p: UInt32) -> UInt32 {
        let luma = ((p >> 16 & 0xFF) * 77 + (p >> 8 & 0xFF) * 150 + (p & 0xFF) * 29) >> 8
        return 0xFF00_0000 | luma * 0x01_0101
    }

    /// The 4 sources for a wallpaper: the frame that `player` shows now, or else `color`.
    /// This is one pass through the 1× pixels, at the start of the transition. An image
    /// that is not pixel art can be large, so it keeps its colours.
    static func make(player: Player?, color: UInt32) -> [Tint] {
        guard let p = player else {
            let g = grey(color)
            return masks.map { m in
                let c = g & m
                return Tint(color: CGColor(srgbRed: CGFloat(c >> 16 & 0xFF) / 255, green: CGFloat(c >> 8 & 0xFF) / 255,
                                           blue: CGFloat(c & 0xFF) / 255, alpha: 1))
            }
        }
        let src = p.front, w = p.width, h = p.height
        let out = p.pixelArt ? masks.compactMap { _ in Player.surface(w, h) } : []
        guard out.count == masks.count, IOSurfaceLock(src, .readOnly, nil) == 0 else {
            return masks.map { _ in Tint(surface: src) }
        }
        let from = UnsafeRawPointer(IOSurfaceGetBaseAddress(src)), stride = IOSurfaceGetBytesPerRow(src)
        for (i, s) in out.enumerated() {
            IOSurfaceLock(s, [], nil)
            let to = IOSurfaceGetBaseAddress(s), toStride = IOSurfaceGetBytesPerRow(s)
            for y in 0..<h {
                let a = (from + y * stride).assumingMemoryBound(to: UInt32.self)
                let b = (to + y * toStride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<w { b[x] = grey(a[x]) & masks[i] }
            }
            IOSurfaceUnlock(s, [], nil)
        }
        IOSurfaceUnlock(src, .readOnly, nil)
        return out.map { Tint(surface: $0) }
    }
}
