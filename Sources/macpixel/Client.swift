import Foundation

func eprint(_ s: String) {
    FileHandle.standardError.write(Data(("macpixel: " + s + "\n").utf8))
}

/// Calls `body` with a `sockaddr_un` for `path`. Nil when the path is too long.
func withSockAddr<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    addr.sun_len = UInt8(len)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, len) }
    }
}

/// Reads up to the first newline (not included) or EOF.
func sockReadLine(_ fd: Int32) -> String? {
    var data: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    while data.count < 1 << 20 {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
        if let i = data.firstIndex(of: 10) {
            data.removeSubrange(i...)
            return String(decoding: data, as: UTF8.self)
        }
    }
    return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
}

@discardableResult
func sockWrite(_ fd: Int32, _ s: String) -> Bool {
    let bytes = Array(s.utf8)
    var done = 0
    while done < bytes.count {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + done, $0.count - done) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        done += n
    }
    return true
}

/// One JSON value + newline. JSON escapes all control characters, so the line has no other newline.
func encodeJSONLine(_ value: Any) -> String {
    let opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    guard let d = try? JSONSerialization.data(withJSONObject: value, options: opts) else {
        return "{\"ok\":false,\"error\":\"internal: cannot encode reply\"}\n"
    }
    return String(decoding: d, as: UTF8.self) + "\n"
}

func decodeJSONLine(_ line: String) -> Any? {
    try? JSONSerialization.jsonObject(with: Data(line.utf8))
}

/// Daemon reply: `{"ok":true, ...fields}` or `{"ok":false,"error":"<message>"}`.
enum Reply {
    case ok([String: Any] = [:])
    case err(String)

    var line: String {
        switch self {
        case .ok(let fields): return encodeJSONLine(fields.merging(["ok": true]) { $1 })
        case .err(let m): return encodeJSONLine(["ok": false, "error": m])
        }
    }
}

/// Socket client (SPEC §3). Request: JSON array of strings, one line. Reply: one JSON object, one line.
enum Client {
    static var socketPath: String { NSTemporaryDirectory() + "macpixel.sock" }

    static func connectSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard withSockAddr(socketPath, { connect(fd, $0, $1) }) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func isRunning() -> Bool {
        guard let fd = connectSocket() else { return false }
        close(fd)
        return true
    }

    /// Returns the exit code (SPEC §4).
    static func send(_ args: [String]) -> Int32 {
        guard let fd = connectSocket() else {
            eprint("daemon not running")
            return 3
        }
        defer { close(fd) }
        guard sockWrite(fd, encodeJSONLine(args)), let line = sockReadLine(fd) else {
            eprint("no reply from daemon")
            return 1
        }
        guard let reply = decodeJSONLine(line) as? [String: Any], let ok = reply["ok"] as? Bool else {
            eprint("bad reply from daemon")
            return 1
        }
        guard ok else {
            eprint(reply["error"] as? String ?? "unknown error")
            return 1
        }
        for s in reply["screens"] as? [[String: Any]] ?? [] { print(screenLine(s)) }
        return 0
    }

    /// `<id> <w>x<h> <file|color #RRGGBB> <state>[ (<reasons>)]`
    static func screenLine(_ s: [String: Any]) -> String {
        func v(_ k: String) -> String { s[k].map { "\($0)" } ?? "?" }
        let what = (s["file"] as? String) ?? "color " + v("color")
        var line = "\(v("id")) \(v("width"))x\(v("height")) \(what) \(v("state"))"
        if let r = s["reasons"] as? [String], !r.isEmpty { line += " (" + r.joined(separator: ",") + ")" }
        return line
    }
}
