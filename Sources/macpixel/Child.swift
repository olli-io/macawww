import Foundation

/// Runs an internal command of this binary as a child process (SPEC §6).
/// Work that needs ImageIO or large buffers runs there, so its memory goes away with the child.
enum Child {
    /// Waits for the child. Returns nil on success, else the error text of the child.
    /// Call on a background queue.
    static func run(_ args: [String]) -> String? {
        let p = Process(), err = Pipe()
        p.executableURL = Bundle.main.executableURL
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return "cannot start the child process: \(error.localizedDescription)" }
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        return text.isEmpty ? "child process failed (status \(p.terminationStatus))" : text
    }

    /// Runs `body` in the child, prints its error to stderr, and exits.
    static func main(_ body: () throws -> Void) -> Never {
        do {
            try body()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
