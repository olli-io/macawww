import AppKit

/// One wallpaper window on one display.
final class Screen {
    let id: CGDirectDisplayID
    let window: NSWindow
    let layer: CALayer
    var player: Player?
    var color: UInt32?

    init(id: CGDirectDisplayID, window: NSWindow, layer: CALayer) {
        self.id = id
        self.window = window
        self.layer = layer
    }
}

/// Window per screen and reconcile on display changes (SPEC §5, §10). Main thread only.
final class Screens {
    private(set) var all: [CGDirectDisplayID: Screen] = [:]
    /// Called after each reconcile.
    var onChange: () -> Void = {}
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
                if e.window.frame != s.frame { e.window.setFrame(s.frame, display: false) }
            } else {
                all[id] = make(id, s.frame)
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

    func show(_ s: Screen, player: Player) {
        guard s.player !== player else { return }
        s.player?.detach(s.layer)
        s.player = player
        s.color = nil
        player.attach(s.layer)
    }

    func show(_ s: Screen, color: UInt32) {
        guard s.player != nil || s.color != color else { return }
        s.player?.detach(s.layer)
        s.player = nil
        s.color = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.layer.contents = nil
        s.layer.backgroundColor = CGColor(srgbRed: CGFloat(color >> 16 & 0xFF) / 255,
                                          green: CGFloat(color >> 8 & 0xFF) / 255,
                                          blue: CGFloat(color & 0xFF) / 255, alpha: 1)
        CATransaction.commit()
    }

    func windows(of p: Player) -> [(window: NSWindow, display: CGDirectDisplayID)] {
        all.values.filter { $0.player === p }.map { ($0.window, $0.id) }
    }

    private func make(_ id: CGDirectDisplayID, _ frame: NSRect) -> Screen {
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

        let layer = CALayer()
        layer.contentsGravity = .resizeAspectFill
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .linear
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.actions = ["contents": NSNull(), "backgroundColor": NSNull()]
        // Layer-hosting view: set the layer before wantsLayer. AppKit does not draw into it.
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.layer = layer
        v.wantsLayer = true
        w.contentView = v
        w.orderFront(nil)
        return Screen(id: id, window: w, layer: layer)
    }
}
