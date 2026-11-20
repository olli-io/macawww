import AppKit
import IOKit.ps

struct PauseReason: OptionSet {
    let rawValue: UInt16
    static let occluded = PauseReason(rawValue: 1 << 0)
    static let displaySleep = PauseReason(rawValue: 1 << 1)
    static let systemSleep = PauseReason(rawValue: 1 << 2)
    static let locked = PauseReason(rawValue: 1 << 3)
    static let sessionInactive = PauseReason(rawValue: 1 << 4)
    static let lowPower = PauseReason(rawValue: 1 << 5)
    static let battery = PauseReason(rawValue: 1 << 6)
    static let user = PauseReason(rawValue: 1 << 7)

    static let names: [(PauseReason, String)] = [
        (.occluded, "occluded"), (.displaySleep, "displaySleep"), (.systemSleep, "systemSleep"),
        (.locked, "locked"), (.sessionInactive, "sessionInactive"), (.lowPower, "lowPower"),
        (.battery, "battery"), (.user, "user"),
    ]

    var list: [String] { PauseReason.names.filter { contains($0.0) }.map(\.1) }
}

/// All pause signals → pause reasons (SPEC §9). Main thread only.
final class Power {
    private(set) var global: PauseReason = []
    /// Displays with a full-screen window of another app (occlusion fallback, SPEC §9).
    private var covered = Set<CGDirectDisplayID>()
    var onChange: () -> Void = {}
    private let pauseOnBattery: Bool
    private var tokens: [NSObjectProtocol] = []

    init(pauseOnBattery: Bool) { self.pauseOnBattery = pauseOnBattery }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        let nc = NotificationCenter.default
        watch(ws, NSWorkspace.screensDidSleepNotification) { $0.set(.displaySleep, true) }
        watch(ws, NSWorkspace.screensDidWakeNotification) { $0.set(.displaySleep, false) }
        watch(ws, NSWorkspace.willSleepNotification) { $0.set(.systemSleep, true) }
        watch(ws, NSWorkspace.didWakeNotification) { $0.set(.systemSleep, false) }
        watch(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.set(.sessionInactive, true) }
        watch(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.set(.sessionInactive, false) }
        watch(ws, NSWorkspace.activeSpaceDidChangeNotification) { $0.spaceChanged() }
        watch(dn, Notification.Name("com.apple.screenIsLocked")) { $0.set(.locked, true) }
        watch(dn, Notification.Name("com.apple.screenIsUnlocked")) { $0.set(.locked, false) }
        watch(nc, ProcessInfo.powerStateDidChangeNotification) { $0.updateLowPower() }
        watch(nc, NSWindow.didChangeOcclusionStateNotification) { $0.onChange() }
        updateLowPower()
        if pauseOnBattery { startBattery() }
    }

    func setUser(_ paused: Bool) { set(.user, paused) }

    /// Reasons for a player that shows on `windows`.
    func reasons(windows: [(window: NSWindow, display: CGDirectDisplayID)]) -> PauseReason {
        var r = global
        let hidden = windows.allSatisfy {
            !$0.window.occlusionState.contains(.visible) || covered.contains($0.display)
        }
        if !windows.isEmpty && hidden { r.insert(.occluded) }
        return r
    }

    private func set(_ r: PauseReason, _ on: Bool) {
        let old = global
        if on { global.insert(r) } else { global.remove(r) }
        if old != global { onChange() }
    }

    private func watch(_ c: NotificationCenter, _ n: Notification.Name, _ f: @escaping (Power) -> Void) {
        tokens.append(c.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
            if let self { f(self) }
        })
    }

    private func updateLowPower() {
        set(.lowPower, ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    // MARK: Full-screen fallback. One check per space change, plus one after the animation. No polling.

    private func spaceChanged() {
        updateCovered()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) { [weak self] in
            self?.updateCovered()
        }
    }

    private func updateCovered() {
        var found = Set<CGDirectDisplayID>()
        let me = Int(getpid())
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
            for s in NSScreen.screens {
                guard let id = Screens.displayID(s) else { continue }
                let bounds = CGDisplayBounds(id)
                let hit = list.contains { w in
                    guard (w[kCGWindowLayer as String] as? Int) == 0,
                          (w[kCGWindowOwnerPID as String] as? Int) != me,
                          let d = w[kCGWindowBounds as String] as? NSDictionary,
                          let r = CGRect(dictionaryRepresentation: d as CFDictionary) else { return false }
                    return r == bounds
                }
                if hit { found.insert(id) }
            }
        }
        if found != covered {
            covered = found
            onChange()
        }
    }

    // MARK: Battery

    private func startBattery() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<Power>.fromOpaque(ctx).takeUnretainedValue().updateBattery()
        }, ctx)?.takeRetainedValue()
        if let src { CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes) }
        updateBattery()
    }

    private func updateBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return }
        set(.battery, (type as String) == kIOPMBatteryPowerKey)
    }
}
