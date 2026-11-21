import AppKit
import IOSurface

/// Shows one transition on the screens that one request changed (SPEC §17). Main thread only.
///
/// The window server composes the transition. Above the image layer of each screen (which
/// already shows the new wallpaper) there is a temporary `box` layer:
/// - `old`: a copy of the image layer before the change. Its mask is the right half of the grid.
/// - grid kinds: a layer with the left half of the grid (the colours).
/// - slide: one clip layer for each band, with a copy of the new image layer.
final class Transition {
    private struct Part {
        let box: CALayer
        let old: CALayer
        let oldPlayer: Player?
        let newPlayer: Player?
        let bands: [(clip: CALayer, img: CALayer)]
        /// The grid in the root layer, in points. A cell is `cell` points.
        let grid: CGRect
        let cell: CGFloat
        /// Origin of the new image layer.
        let home: CGPoint
    }

    private let effect: Effect
    /// The grid, 2 × gridW by gridH (see `Effect.render`). `front` is on screen.
    private var front: IOSurfaceRef?
    private var back: IOSurfaceRef?
    private var gridLayers: [CALayer] = []
    private var parts: [Part] = []
    private var pending: (old: CALayer, player: Player?)?
    private var timer: DispatchSourceTimer?
    private var onEnd: () -> Void = {}
    private var ended = false
    /// The windows that show this transition.
    private(set) var windows: [(window: NSWindow, display: CGDirectDisplayID)] = []

    init?(_ kind: FxKind) {
        guard kind != .disabled else { return nil }
        effect = Effect(kind: kind, seed: DispatchTime.now().uptimeNanoseconds)
        guard kind != .slide else { return }
        let w = Effect.gridW * 2, h = Effect.gridH
        guard let f = Player.surface(w, h), let b = Player.surface(w, h) else { return nil }
        front = f
        back = b
        IOSurfaceLock(f, [], nil)
        effect.render(IOSurfaceGetBaseAddress(f), stride: IOSurfaceGetBytesPerRow(f))
        IOSurfaceUnlock(f, [], nil)
    }

    /// The smallest whole-number scale where the grid covers the screen, and the grid
    /// origin. Sizes in pixels.
    static func placement(screen: (w: Int, h: Int)) -> (k: Int, x: Int, y: Int) {
        let w = Effect.gridW, h = Effect.gridH
        let k = max(1, (screen.w + w - 1) / w, (screen.h + h - 1) / h)
        return (k, (screen.w - w * k) / 2, (screen.h - h * k) / 2)
    }

    private static func replica(_ l: CALayer) -> CALayer {
        let r = CALayer()
        r.actions = l.actions
        r.frame = l.frame
        r.contentsGravity = l.contentsGravity
        r.magnificationFilter = l.magnificationFilter
        r.minificationFilter = l.minificationFilter
        r.contents = l.contents
        r.backgroundColor = l.backgroundColor
        return r
    }

    private func gridLayer(x: CGFloat) -> CALayer {
        let l = CALayer()
        l.contentsGravity = .resize
        l.magnificationFilter = .nearest
        l.contentsRect = CGRect(x: x, y: 0, width: 0.5, height: 1)
        l.contents = front
        gridLayers.append(l)
        return l
    }

    /// Call before `Screens.show`. Copies the look of the screen. The copy is a layer of
    /// the old player, so the old animation continues and `detach` does not stop it.
    func before(_ s: Screen) {
        let old = Transition.replica(s.layer)
        s.player?.attach(old)
        pending = (old, s.player)
    }

    /// Call after `Screens.show`. `changed`: the screen shows a different wallpaper now.
    func after(_ s: Screen, changed: Bool) {
        guard let (old, oldPlayer) = pending else { return }
        pending = nil
        guard changed, let root = s.layer.superlayer else {
            oldPlayer?.detach(old)
            return
        }
        let at = Transition.placement(screen: s.pixelSize)
        let cell = CGFloat(at.k) / s.scale
        let grid = CGRect(x: CGFloat(at.x) / s.scale, y: CGFloat(at.y) / s.scale,
                          width: CGFloat(Effect.gridW) * cell, height: CGFloat(Effect.gridH) * cell)
        var bands: [(clip: CALayer, img: CALayer)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = CALayer()
        box.frame = root.bounds
        box.addSublayer(old)
        if effect.kind == .slide {
            for _ in 0..<Effect.bands {
                let clip = CALayer()
                clip.masksToBounds = true
                let img = Transition.replica(s.layer)
                s.player?.attach(img)
                clip.addSublayer(img)
                box.addSublayer(clip)
                bands.append((clip, img))
            }
        } else {
            // The frame of a mask is in the coordinates of its layer.
            let mask = gridLayer(x: 0.5)
            mask.frame = grid.offsetBy(dx: -old.frame.minX, dy: -old.frame.minY)
            old.mask = mask
            let colors = gridLayer(x: 0)
            colors.frame = grid
            box.addSublayer(colors)
        }
        root.addSublayer(box)
        CATransaction.commit()
        parts.append(Part(box: box, old: old, oldPlayer: oldPlayer, newPlayer: s.player, bands: bands,
                          grid: grid, cell: cell, home: s.layer.frame.origin))
        windows.append((s.window, s.id))
    }

    /// Starts the steps. Returns false when no screen changed. Calls `onEnd` one time, at the end.
    func start(onEnd: @escaping () -> Void) -> Bool {
        guard !parts.isEmpty, !ended else { return false }
        self.onEnd = onEnd
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in self?.tick() }
        let ms = DispatchTimeInterval.milliseconds(Effect.stepMs)
        t.schedule(deadline: .now() + ms, repeating: ms, leeway: .milliseconds(3))
        timer = t
        t.activate()
        return true
    }

    /// One step. Only the grid surface gets pixel writes. No logging.
    private func tick() {
        guard effect.advance() else { return end() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if effect.kind == .slide {
            for p in parts { slide(p) }
        } else if let b = back, IOSurfaceLock(b, [], nil) == 0 {
            // A lock failure skips this step. The next step draws the full grid.
            effect.render(IOSurfaceGetBaseAddress(b), stride: IOSurfaceGetBytesPerRow(b))
            IOSurfaceUnlock(b, [], nil)
            for l in gridLayers { l.contents = b }
            back = front
            front = b
        }
        CATransaction.commit()
    }

    /// Moves the bands of one screen to the current step. Layer y goes up, grid rows go down.
    private func slide(_ p: Part) {
        let step = effect.step
        var band = max(0, step - Effect.slideSteps)
        let last = min(step, Effect.bands)
        while band < last {
            let edge = Effect.slideEdge(band: band, step: step)
            let y0 = band * Effect.bandH, y1 = min(Effect.gridH, y0 + Effect.bandH)
            let clip = CGRect(x: p.grid.minX, y: p.grid.maxY - CGFloat(y1) * p.cell,
                              width: CGFloat(edge) * p.cell, height: CGFloat(y1 - y0) * p.cell)
            let shift = CGFloat(Effect.gridW - edge) * p.cell
            p.bands[band].clip.frame = clip
            p.bands[band].img.frame.origin = CGPoint(x: p.home.x - shift - clip.minX, y: p.home.y - clip.minY)
            band += 1
        }
    }

    /// Removes the temporary layers. The screens then show only the new wallpaper.
    func end() {
        guard !ended else { return }
        ended = true
        timer?.cancel()
        timer = nil
        if let (old, player) = pending { player?.detach(old) }
        pending = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for p in parts {
            p.box.removeFromSuperlayer()
            p.oldPlayer?.detach(p.old)
            for b in p.bands { p.newPlayer?.detach(b.img) }
        }
        CATransaction.commit()
        parts = []
        gridLayers = []
        onEnd()
    }
}

extension Effect {
    /// Writes the grid as BGRA pixels, 2 × gridW by gridH. Row 0 is the top row.
    /// Left half: the colours, above the wallpapers. Right half: the mask of the old
    /// wallpaper (alpha 0 where the cell shows the new one). No allocation.
    func render(_ base: UnsafeMutableRawPointer, stride: Int) {
        let w = Effect.gridW
        disp.withUnsafeBufferPointer { d in
            for y in 0..<Effect.gridH {
                let row = (base + y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<w {
                    let code = d[y * w + x]
                    row[x] = code >> 24 == 0xFF ? code : code == Effect.veil ? Effect.veilPixel : 0
                    row[w + x] = code == Effect.new ? 0 : 0xFF00_0000
                }
            }
        }
    }
}
