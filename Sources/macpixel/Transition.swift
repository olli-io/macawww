import AppKit
import IOSurface

/// Shows one transition on the screens that one request changed (SPEC §17). Main thread only.
///
/// The window server composes the transition. Above the image layer of each screen (which
/// already shows the new wallpaper) there is a temporary `box` layer:
/// - `old`: a copy of the image layer before the change. Its mask is the right half of the grid.
/// - one clip layer for each piece of the effect, with a copy of an image layer.
/// - grid kinds: a layer with the left half of the grid (the colours).
final class Transition {
    private struct Part {
        let box: CALayer
        let old: CALayer
        let oldPlayer: Player?
        let newPlayer: Player?
        let pieces: [(clip: CALayer, img: CALayer)]
        /// vhstape: the sources of the pieces.
        let tints: [Tint]
        /// The grid in the root layer, in points. A cell is `cell` points.
        let grid: CGRect
        let cell: CGFloat
        /// Width of the screen in points.
        let width: CGFloat
        /// Origins of the new and of the old image layer.
        let newHome: CGPoint
        let oldHome: CGPoint
    }

    private let effect: Effect
    /// The grid, 2 × gridW by gridH (see `Effect.render`). `front` is on screen.
    private var front: IOSurfaceRef?
    private var back: IOSurfaceRef?
    private var gridLayers: [CALayer] = []
    private var parts: [Part] = []
    /// The piece that each clip layer of each part shows.
    private var shown: [[Piece]] = []
    private var pending: (old: CALayer, player: Player?, color: UInt32)?
    private var timer: DispatchSourceTimer?
    private var onEnd: () -> Void = {}
    private var ended = false
    /// The windows that show this transition.
    private(set) var windows: [(window: NSWindow, display: CGDirectDisplayID)] = []

    init?(_ kind: FxKind) {
        guard kind != .disabled else { return nil }
        effect = Effect(kind: kind, seed: DispatchTime.now().uptimeNanoseconds)
        guard effect.hasGrid else { return }
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
        Screens.placement(art: (Effect.gridW, Effect.gridH), screen: screen)
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
        pending = (old, s.player, s.color ?? 0)
    }

    /// Call after `Screens.show`. `changed`: the screen shows a different wallpaper now.
    func after(_ s: Screen, changed: Bool) {
        guard let (old, oldPlayer, oldColor) = pending else { return }
        pending = nil
        guard changed, let root = s.layer.superlayer else {
            oldPlayer?.detach(old)
            return
        }
        let at = Transition.placement(screen: s.pixelSize)
        let cell = CGFloat(at.k) / s.scale
        let grid = CGRect(x: CGFloat(at.x) / s.scale, y: CGFloat(at.y) / s.scale,
                          width: CGFloat(Effect.gridW) * cell, height: CGFloat(Effect.gridH) * cell)
        // vhstape moves the old wallpaper. The other effects move the new one.
        let tints = effect.kind == .vhstape ? Tint.make(player: oldPlayer, color: oldColor) : []
        var pieces: [(clip: CALayer, img: CALayer)] = []
        pieces.reserveCapacity(effect.pieces.count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = CALayer()
        box.frame = root.bounds
        box.addSublayer(old)
        for _ in effect.pieces {
            let clip = CALayer()
            clip.masksToBounds = true
            clip.isHidden = true
            let img = Transition.replica(tints.isEmpty ? s.layer : old)
            if tints.isEmpty {
                s.player?.attach(img)
            } else {
                clip.backgroundColor = CGColor(gray: 0, alpha: 1)  // the end of a moved line
            }
            clip.addSublayer(img)
            box.addSublayer(clip)
            pieces.append((clip, img))
        }
        if effect.hasGrid {
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
        parts.append(Part(box: box, old: old, oldPlayer: oldPlayer, newPlayer: s.player, pieces: pieces,
                          tints: tints, grid: grid, cell: cell, width: root.bounds.width,
                          newHome: s.layer.frame.origin, oldHome: old.frame.origin))
        shown.append([Piece](repeating: Piece(), count: pieces.count))
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

    /// One step. Only the grid surface gets pixel writes. No allocation, no logging.
    private func tick() {
        guard effect.advance() else { return end() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let b = back, IOSurfaceLock(b, [], nil) == 0 {
            // A lock failure skips this step. The next step draws the full grid.
            effect.render(IOSurfaceGetBaseAddress(b), stride: IOSurfaceGetBytesPerRow(b))
            IOSurfaceUnlock(b, [], nil)
            for l in gridLayers { l.contents = b }
            back = front
            front = b
        }
        // Only the layers of the pieces that changed get new values.
        for p in 0..<parts.count {
            for i in 0..<effect.pieces.count where shown[p][i] != effect.pieces[i] {
                shown[p][i] = effect.pieces[i]
                place(parts[p], i, effect.pieces[i])
            }
        }
        CATransaction.commit()
    }

    /// Shows the piece `pc` with clip layer `i` of one screen. Layer y goes up, grid rows go down.
    private func place(_ p: Part, _ i: Int, _ pc: Piece) {
        let (clip, img) = p.pieces[i]
        clip.isHidden = pc.w == 0 || pc.h == 0
        if clip.isHidden { return }
        let r = CGRect(x: p.grid.minX + CGFloat(pc.x) * p.cell, y: p.grid.maxY - CGFloat(pc.y + pc.h) * p.cell,
                       width: CGFloat(pc.w) * p.cell, height: CGFloat(pc.h) * p.cell)
        var dx = CGFloat(pc.dx) * p.cell, dy = CGFloat(pc.dy) * p.cell
        var home = p.newHome
        if pc.src == 0 {
            // The grid can be larger than the screen. The limits keep the source inside the
            // screen, which the wallpaper covers.
            dx = min(dx, max(0, p.width - r.maxX))
            dy = min(dy, max(0, r.minY))
        } else {
            home = p.oldHome
            let tint = p.tints[pc.src - 1]
            img.contents = tint.surface
            if let color = tint.color { img.backgroundColor = color }
        }
        clip.frame = r
        img.frame.origin = CGPoint(x: home.x - dx - r.minX, y: home.y + dy - r.minY)
    }

    /// Removes the temporary layers. The screens then show only the new wallpaper.
    func end() {
        guard !ended else { return }
        ended = true
        timer?.cancel()
        timer = nil
        if let (old, player, _) = pending { player?.detach(old) }
        pending = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for p in parts {
            p.box.removeFromSuperlayer()
            p.oldPlayer?.detach(p.old)
            if p.tints.isEmpty { for piece in p.pieces { p.newPlayer?.detach(piece.img) } }
        }
        CATransaction.commit()
        parts = []
        shown = []
        gridLayers = []
        onEnd()
    }
}

extension Effect {
    /// False for slide, which has only pieces.
    var hasGrid: Bool { !disp.isEmpty }

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
                    row[x] = code >> 24 == 0xFF ? code : 0
                    row[w + x] = code == Effect.new ? 0 : 0xFF00_0000
                }
            }
        }
    }
}
