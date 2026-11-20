import AppKit
import ImageIO

/// Keeps the macOS desktop picture equal to the macawww wallpaper (SPEC §16). Main thread only,
/// except the two `render` functions, which run in a child process.
final class SystemWallpaper {
    private struct Want {
        let url: URL
        let fill: Bool        // true: macOS scales the file (aspect fill). false: the file has the screen size.
        let make: [String]?   // child command that creates `url`
    }

    private var want: [CGDirectDisplayID: Want] = [:]
    private var making = Set<String>()
    private let queue: DispatchQueue
    private var token: NSObjectProtocol?

    /// Files that the cache eviction must keep.
    var files: Set<String> { Set(want.values.map(\.url.path)) }

    init(queue: DispatchQueue) { self.queue = queue }

    func start() {
        // The macOS API sets the picture of the active Space only. Set it again on each Space change.
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            for id in want.keys { apply(id) }
        }
    }

    /// Call when the image, the colour or the pixel size of a screen changed.
    func sync(_ s: Screen) {
        let px = s.pixelSize
        if let p = s.player {
            if p.pixelArt, Screens.placement(art: (p.width, p.height), screen: px) != nil {
                // Pixel art: one PNG of the screen size, with the scale and the cut of the layer.
                let url = Cache.dir.appendingPathComponent("\(p.key)-\(px.w)x\(px.h).png")
                want[s.id] = Want(url: url, fill: false,
                                  make: ["still", p.cacheURL, url.path, String(px.w), String(px.h)])
            } else {
                want[s.id] = Want(url: URL(fileURLWithPath: p.path), fill: true, make: nil)
            }
        } else if let c = s.color {
            let hex = String(format: "%06X", c)
            let url = Cache.dir.appendingPathComponent("color-\(hex).png")
            want[s.id] = Want(url: url, fill: false, make: ["still-color", hex, url.path])
        } else {
            return
        }
        apply(s.id)
    }

    private func apply(_ id: CGDirectDisplayID) {
        guard let w = want[id] else { return }
        guard let screen = NSScreen.screens.first(where: { Screens.displayID($0) == id }) else {
            want[id] = nil  // the display is gone
            return
        }
        if let make = w.make, !FileManager.default.fileExists(atPath: w.url.path) {
            guard making.insert(w.url.path).inserted else { return }
            queue.async {
                let err = Child.run(make)
                DispatchQueue.main.async { [self] in
                    making.remove(w.url.path)
                    if let err {
                        logger.error("system wallpaper: \(err, privacy: .public)")
                    } else {
                        for (id, x) in want where x.url == w.url { apply(id) }
                    }
                }
            }
            return
        }
        let ws = NSWorkspace.shared
        guard ws.desktopImageURL(for: screen)?.path != w.url.path else { return }
        let scaling: NSImageScaling = w.fill ? .scaleProportionallyUpOrDown : .scaleAxesIndependently
        do {
            try ws.setDesktopImageURL(w.url, for: screen, options: [
                .imageScaling: NSNumber(value: scaling.rawValue),
                .allowClipping: NSNumber(value: w.fill),
                .fillColor: NSColor.black,
            ])
        } catch {
            logger.error("system wallpaper: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Child process

    /// Writes frame 0 of a pixel-art cache file as a PNG of the screen size (pixels).
    static func renderStill(cache: URL, to dst: URL, width: Int, height: Int) throws {
        let c = try CacheFile(url: cache)
        guard (1...Cache.maxSide).contains(width), (1...Cache.maxSide).contains(height),
              let at = Screens.placement(art: (c.width, c.height), screen: (width, height)) else {
            throw MCWError.decode("no integer scale for \(width)x\(height)")
        }
        let buf = calloc(c.width * c.height * 4, 1)!, scratch = malloc(Blit.scratchSize)!
        defer { free(buf); free(scratch) }
        Blit.apply(c, frame: 0, base: buf, stride: c.width * 4, scratch: scratch, tmp: nil)
        guard let art = FrameEncoder.context(buf, c.width, c.height)?.makeImage(),
              let out = bitmap(width, height) else { throw MCWError.decode("cannot create bitmap context") }
        out.interpolationQuality = .none
        out.draw(art, in: CGRect(x: at.x, y: at.y, width: c.width * at.k, height: c.height * at.k))
        try write(out, dst)
    }

    static func renderColor(_ color: UInt32, to dst: URL) throws {
        guard let out = bitmap(16, 16) else { throw MCWError.decode("cannot create bitmap context") }
        out.setFillColor(CGColor(srgbRed: CGFloat(color >> 16 & 0xFF) / 255, green: CGFloat(color >> 8 & 0xFF) / 255,
                                 blue: CGFloat(color & 0xFF) / 255, alpha: 1))
        out.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        try write(out, dst)
    }

    /// Opaque sRGB bitmap, black.
    private static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: space, bitmapInfo: info)
        ctx?.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    /// PNG to a temp file, then rename.
    private static func write(_ ctx: CGContext, _ dst: URL) throws {
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).\(getpid()).tmp")
        guard let img = ctx.makeImage(),
              let d = CGImageDestinationCreateWithURL(tmp as CFURL, "public.png" as CFString, 1, nil) else {
            throw MCWError.io("cannot create \(tmp.path)")
        }
        CGImageDestinationAddImage(d, img, nil)
        guard CGImageDestinationFinalize(d), rename(tmp.path, dst.path) == 0 else {
            unlink(tmp.path)
            throw MCWError.io("cannot write \(dst.path)")
        }
    }
}
