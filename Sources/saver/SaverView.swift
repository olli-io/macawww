import AppKit
import ScreenSaver

/// The screensaver view (SPEC §18): one view per screen. It shows the wallpaper of its screen,
/// or the `screensaver` image of the config file.
@objc(MacpixelSaverView)
final class MacpixelSaverView: ScreenSaverView {
    private var image = CALayer()
    private var content = SaverContent.none
    private var active = false
    private var request = 0
    private var stopObserver: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit {
        if let stopObserver { DistributedNotificationCenter.default().removeObserver(stopObserver) }
        if case .player(let p) = content { p.detach(image) }
    }

    private func setUp() {
        let layers = Layout.layers()
        image = layers.image
        // Layer-hosting view: set the layer before wantsLayer. AppKit does not draw into it.
        layer = layers.root
        wantsLayer = true
        // The player has its own timer. `animateOneFrame` has no function here.
        animationTimeInterval = 3600
        observeStop()
    }

    // MARK: Content

    private var displayID: UInt32? {
        (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func load() {
        request += 1
        let id = request
        SaverSource.resolve(display: displayID) { [weak self] c in
            guard let self, id == self.request else { return }
            self.show(c)
        }
    }

    private func show(_ new: SaverContent) {
        if case .player(let p) = content { p.detach(image) }
        content = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.contents = nil
        image.backgroundColor = CGColor(gray: 0, alpha: 1)
        CATransaction.commit()
        switch new {
        case .player(let p):
            p.attach(image)
            if active { p.setRunning(true) }
        case .color(let c): image.backgroundColor = Layout.color(c)
        case .none: break
        }
        place()
    }

    /// Pixel art has the integer scale of the wallpaper (SPEC §5). The small preview fills its view.
    private func place() {
        var art: (w: Int, h: Int)?
        if case .player(let p) = content, p.pixelArt, !isPreview { art = (p.width, p.height) }
        let scale = window?.backingScaleFactor ?? 2
        let at = Layout.imageFrame(art: art, size: bounds.size, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.frame = at.frame
        image.contentsGravity = at.gravity
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The screen is known now.
        if window != nil { load() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        place()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    // MARK: Animation

    override func startAnimation() {
        super.startAnimation()
        active = true
        if case .player(let p) = content { p.setRunning(true) }
    }

    override func stopAnimation() {
        super.stopAnimation()
        active = false
        if case .player(let p) = content { p.setRunning(false) }
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    // MARK: Stop

    /// macOS 14 and later do not destroy the views when the screensaver stops, and the host
    /// process continues to run them. The view stops the player and stops the host process.
    private func observeStop() {
        guard ProcessInfo.processInfo.processName.contains("legacyScreenSaver") else { return }
        stopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if case .player(let p) = self.content { p.setRunning(false) }
            if !self.isPreview { exit(0) }
        }
    }
}
