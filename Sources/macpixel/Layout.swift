import QuartzCore

/// Scale and position of an image on a screen (SPEC §5). No AppKit.
enum Layout {
    /// Integer scale for pixel art (SPEC §5): the smallest k where art × k covers the screen.
    /// Sizes in pixels. Never less than 1. There is no aspect-fill fallback: the overflow is cut.
    static func integerScale(art: (w: Int, h: Int), screen: (w: Int, h: Int)) -> Int {
        let w = max(1, art.w), h = max(1, art.h)
        return max(1, (screen.w + w - 1) / w, (screen.h + h - 1) / h)
    }

    /// Scale and position (pixels, origin bottom left) of pixel art on a screen. Centred on whole pixels.
    static func placement(art: (w: Int, h: Int), screen: (w: Int, h: Int)) -> (k: Int, x: Int, y: Int) {
        let k = integerScale(art: art, screen: screen)
        return (k, (screen.w - art.w * k) / 2, (screen.h - art.h * k) / 2)
    }

    /// Size in backing pixels of a view of `size` points.
    static func pixels(_ size: CGSize, scale: CGFloat) -> (w: Int, h: Int) {
        (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
    }

    /// Frame (points) and gravity of the image layer in a view of `size` points.
    /// `art` = the size of pixel art, nil for other images: they fill the view.
    static func imageFrame(art: (w: Int, h: Int)?, size: CGSize,
                           scale: CGFloat) -> (frame: CGRect, gravity: CALayerContentsGravity) {
        guard let art else { return (CGRect(origin: .zero, size: size), .resizeAspectFill) }
        let at = placement(art: art, screen: pixels(size, scale: scale))
        // The root layer cuts the part outside the view.
        let frame = CGRect(x: CGFloat(at.x) / scale, y: CGFloat(at.y) / scale,
                           width: CGFloat(art.w * at.k) / scale, height: CGFloat(art.h * at.k) / scale)
        return (frame, .resize)
    }

    /// The layers of a layer-hosting view: a black root that cuts, and the image layer in it.
    static func layers() -> (root: CALayer, image: CALayer) {
        let root = CALayer()
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.masksToBounds = true
        let layer = CALayer()
        layer.contentsGravity = .resizeAspectFill
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .linear
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.actions = ["contents": NSNull(), "backgroundColor": NSNull(), "bounds": NSNull(),
                         "position": NSNull()]
        root.addSublayer(layer)
        return (root, layer)
    }

    /// `rgb` = 0xRRGGBB.
    static func color(_ rgb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
