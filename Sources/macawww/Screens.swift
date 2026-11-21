import AppKit

/// One wallpaper window on one display.
final class Screen {
    let id: CGDirectDisplayID
    let window: NSWindow
    /// Shows the image or the colour. A sublayer of the root layer of the window.
    let layer: CALayer
    /// Backing pixels for each point.
    var scale: CGFloat
    var player: Player?
    var color: UInt32?
    /// Size in backing pixels.
    var pixelSize: (w: Int, h: Int) {
        let size = window.frame.size
        return (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
    }

    init(id: CGDirectDisplayID, window: NSWindow, layer: CALayer, scale: CGFloat) {
        self.id = id
        self.window = window
        self.layer = layer
        self.scale = scale
    }
}

/// Window per screen and reconcile on display changes (SPEC §5, §10). Main thread only.
final class Screens {
    private(set) var all: [CGDirectDisplayID: Screen] = [:]
    /// Called after each reconcile.
    var onChange: () -> Void = {}
    /// Called after the image, the colour, the frame or the scale of a screen changed.
    var onLayout: (Screen) -> Void = { _ in }
    private var pending: DispatchWorkItem?
    private var tokens: [NSObjectProtocol] = []

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func start() {
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                     object: nil, queue: .main) { [weak self] _ in self?.schedule() })
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            tokens.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                self?.schedule()
            })
        }
        reconcile()
    }

    /// Debounce 250 ms.
    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconcile() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
    }

    func reconcile() {
        var seen = Set<CGDirectDisplayID>()
        for s in NSScreen.screens {
            guard let id = Screens.displayID(s) else { continue }
            seen.insert(id)
            if let e = all[id] {
                guard e.window.frame != s.frame || e.scale != s.backingScaleFactor else { continue }
                e.window.setFrame(s.frame, display: false)
                e.scale = s.backingScaleFactor
                layout(e)
            } else {
                let e = make(id, s.frame, s.backingScaleFactor)
                all[id] = e
                layout(e)
            }
        }
        for id in Array(all.keys) where !seen.contains(id) {
            guard let e = all.removeValue(forKey: id) else { continue }
            e.player?.detach(e.layer)
            e.player = nil
            e.window.orderOut(nil)
            e.window.close()
        }
        onChange()
    }

    /// Returns false when the screen already shows this player.
    @discardableResult
    func show(_ s: Screen, player: Player) -> Bool {
        guard s.player !== player else { return false }
        s.player?.detach(s.layer)
        s.player = player
        s.color = nil
        player.attach(s.layer)
        layout(s)
        return true
    }

    /// Returns false when the screen already shows this colour.
    @discardableResult
    func show(_ s: Screen, color: UInt32) -> Bool {
        guard s.player != nil || s.color != color else { return false }
        s.player?.detach(s.layer)
        s.player = nil
        s.color = color
        layout(s)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.layer.contents = nil
        s.layer.backgroundColor = CGColor(srgbRed: CGFloat(color >> 16 & 0xFF) / 255,
                                          green: CGFloat(color >> 8 & 0xFF) / 255,
                                          blue: CGFloat(color & 0xFF) / 255, alpha: 1)
        CATransaction.commit()
        return true
    }

    func windows(of p: Player) -> [(window: NSWindow, display: CGDirectDisplayID)] {
        all.values.filter { $0.player === p }.map { ($0.window, $0.id) }
    }

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

    /// Sets the frame of the image layer. Each screen has its own pixel size, thus its own k.
    private func layout(_ s: Screen) {
        var frame = CGRect(origin: .zero, size: s.window.frame.size)
        var gravity = CALayerContentsGravity.resizeAspectFill
        if let p = s.player, p.pixelArt {
            let at = Screens.placement(art: (p.width, p.height), screen: s.pixelSize)
            // The root layer cuts the part outside the screen.
            frame = CGRect(x: CGFloat(at.x) / s.scale, y: CGFloat(at.y) / s.scale,
                           width: CGFloat(p.width * at.k) / s.scale, height: CGFloat(p.height * at.k) / s.scale)
            gravity = .resize
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.layer.frame = frame
        s.layer.contentsGravity = gravity
        CATransaction.commit()
        onLayout(s)
    }

    private func make(_ id: CGDirectDisplayID, _ frame: NSRect, _ scale: CGFloat) -> Screen {
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.hasShadow = false
        w.backgroundColor = .black
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none

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
        // Layer-hosting view: set the layer before wantsLayer. AppKit does not draw into it.
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.layer = root
        v.wantsLayer = true
        w.contentView = v
        w.orderFront(nil)
        return Screen(id: id, window: w, layer: layer, scale: scale)
    }
}
