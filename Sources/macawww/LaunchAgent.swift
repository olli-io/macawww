import Foundation

/// Start at login (SPEC §12).
enum LaunchAgent {
    static let label = "io.macawww.daemon"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    private static var domain: String { "gui/\(getuid())" }

    static func install() -> Int32 {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            eprint("cannot find own binary path")
            return 1
        }
        let log = home.appendingPathComponent("Library/Logs/macawww.log")
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardErrorPath": log.path,
        ]
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            eprint("write \(plistURL.path): \(error.localizedDescription)")
            return 1
        }
        if launchctl(["print", "\(domain)/\(label)"], quiet: true) == 0 {
            launchctl(["bootout", "\(domain)/\(label)"], quiet: true)
        }
        guard launchctl(["bootstrap", domain, plistURL.path]) == 0 else {
            eprint("launchctl bootstrap failed")
            return 1
        }
        return 0
    }

    static func uninstall() -> Int32 {
        launchctl(["bootout", "\(domain)/\(label)"], quiet: true)
        do {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        } catch {
            eprint("remove \(plistURL.path): \(error.localizedDescription)")
            return 1
        }
        return 0
    }

    @discardableResult
    private static func launchctl(_ args: [String], quiet: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        if quiet {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
