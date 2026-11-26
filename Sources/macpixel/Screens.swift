import AppKit

/// One wallpaper window on one display.
final class Screen: Canvas {
    let id: CGDirectDisplayID
    let window: NSWindow
    /// Shows the image or the colour. A sublayer of the root layer of the window.
    let layer: CALayer
    var image: CALayer { layer }
    /// Backing pixels for each point.
    var scale: CGFloat
    var player: Player?
    var color: UInt32?
    /// The strip behind the menu bar (SPEC §5). nil: no `menubar` colour.
    var bar: CALayer?
    /// Height of the menu bar area in points.
    var barHeight: CGFloat = 0
    /// Height of the strip in backing pixels. 0: no strip.
    var barPixels: Int { bar == nil ? 0 : Int((barHeight * scale).rounded()) }
    /// Size in backing pixels.
    var pixelSize: (w: Int, h: Int) {
        Layout.pixels(window.frame.size, scale: scale)
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
    /// The `menubar` colour of the config. Set it before `start`.
    var menubar: UInt32?
    private var pending: DispatchWorkItem?
    private var tokens: [NSObjectProtocol] = []

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Height (points) of the menu bar area: the notch area, or else the menu bar. 0 when there is none.
    /// `window`: the height of the menu bar window of the display (see `menuBars`).
    static func barHeight(_ s: NSScreen, window: CGFloat) -> CGFloat {
        barHeight(frame: s.frame, visible: s.visibleFrame, safeTop: s.safeAreaInsets.top, window: window)
    }

    /// Height (points) of the menu bar area from the frames of a screen. Never less than 0.
    static func barHeight(frame: CGRect, visible: CGRect, safeTop: CGFloat = 0, window: CGFloat = 0) -> CGFloat {
        max(0, safeTop, frame.maxY - visible.maxY, window)
    }

    /// Height (points) of the menu bar window of the window server on each display.
    /// When the displays do not have separate Spaces, a screen that is not the main screen
    /// can have a menu bar that its `visibleFrame` does not include. Layer and bounds only:
    /// they need no screen recording permission. One call per reconcile.
    static func menuBars(_ ids: [CGDirectDisplayID]) -> [CGDirectDisplayID: CGFloat] {
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [:] }
        let windows: [CGRect] = list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == level,
                  let d = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: d as CFDictionary)
        }
        return menuBars(windows, displays: ids.map { ($0, CGDisplayBounds($0)) })
    }

    /// A menu bar window starts at the top of its display and has the width of the display.
    /// Bounds in global display coordinates (origin top left).
    static func menuBars(_ windows: [CGRect], displays: [(CGDirectDisplayID, CGRect)]) -> [CGDirectDisplayID: CGFloat] {
        var out: [CGDirectDisplayID: CGFloat] = [:]
        for (id, b) in displays {
            for r in windows where r.minY == b.minY && r.minX == b.minX && r.width == b.width && r.height < b.height {
                out[id] = max(out[id] ?? 0, r.height)
            }
        }
        return out
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
        let bars = menubar == nil ? [:] : Screens.menuBars(NSScreen.screens.compactMap(Screens.displayID))
        for s in NSScreen.screens {
            guard let id = Screens.displayID(s) else { continue }
            seen.insert(id)
            let bar = Screens.barHeight(s, window: bars[id] ?? 0)
            if let e = all[id] {
                guard e.window.frame != s.frame || e.scale != s.backingScaleFactor
                    || e.barHeight != bar else { continue }
                e.window.setFrame(s.frame, display: false)
                e.scale = s.backingScaleFactor
                e.barHeight = bar
                layout(e)
            } else {
                let e = make(id, s.frame, s.backingScaleFactor)
                e.barHeight = bar
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
        s.layer.backgroundColor = Layout.color(color)
        CATransaction.commit()
        return true
    }

    func windows(of p: Player) -> [(window: NSWindow, display: CGDirectDisplayID)] {
        all.values.filter { $0.player === p }.map { ($0.window, $0.id) }
    }

    /// Sets the frame of the image layer. Each screen has its own pixel size, thus its own k.
    private func layout(_ s: Screen) {
        let art = s.player.flatMap { $0.pixelArt ? (w: $0.width, h: $0.height) : nil }
        let (frame, gravity) = Layout.imageFrame(art: art, size: s.window.frame.size, scale: s.scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.layer.frame = frame
        s.layer.contentsGravity = gravity
        let size = s.window.frame.size
        s.bar?.frame = CGRect(x: 0, y: size.height - s.barHeight, width: size.width, height: s.barHeight)
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

        let (root, layer) = Layout.layers()
        // Layer-hosting view: set the layer before wantsLayer. AppKit does not draw into it.
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.layer = root
        v.wantsLayer = true
        w.contentView = v
        w.orderFront(nil)
        let s = Screen(id: id, window: w, layer: layer, scale: scale)
        if let menubar {
            let bar = CALayer()
            bar.backgroundColor = Layout.color(menubar)
            bar.zPosition = 1  // above the layers of a transition
            bar.actions = ["bounds": NSNull(), "position": NSNull()]
            root.addSublayer(bar)
            s.bar = bar
        }
        return s
    }
}
