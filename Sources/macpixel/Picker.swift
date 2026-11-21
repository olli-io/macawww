import Foundation

/// Interactive file list for `img <dir>` (SPEC §4). Keys come from stdin. The list goes to stderr.
enum Picker {
    static let extensions: Set<String> = ["gif", "png", "jpg", "jpeg"]

    enum Key { case up, down, enter, cancel, other }

    /// Image files in `dir`, in Finder name order. Hidden files and directories are not included.
    static func images(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { !$0.hasDirectoryPath && extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// First visible index, so that `selected` is in a window of `rows` lines.
    static func scrollTop(_ top: Int, selected: Int, rows: Int) -> Int {
        if selected < top { return selected }
        if selected >= top + rows { return selected - rows + 1 }
        return top
    }

    /// One list line. Long names are cut so that the line does not wrap.
    static func line(_ name: String, selected: Bool, cols: Int) -> String {
        let text = String(name.prefix(max(1, cols - 3)))
        return selected ? "\u{1B}[7m> \(text)\u{1B}[0m" : "  \(text)"
    }

    /// Returns the selected file. Nil on cancel or error (the error message is printed).
    static func run(dir: URL) -> URL? {
        let files = images(in: dir)
        guard !files.isEmpty else {
            eprint("no .gif, .png or .jpg files in \(dir.path)")
            return nil
        }
        var saved = termios()
        guard isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1, tcgetattr(STDIN_FILENO, &saved) == 0 else {
            eprint("the file list needs a terminal")
            return nil
        }
        // No line buffer, no echo, no signal keys: Ctrl-C comes as a byte, so the terminal is always restored.
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        put("\u{1B}[?25l")
        var selected = 0, top = 0, drawn = 0
        defer {
            put((drawn > 0 ? "\u{1B}[\(drawn)A" : "") + "\r\u{1B}[J\u{1B}[?25h")
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
        }
        while true {
            let (termRows, cols) = terminalSize()
            let rows = min(files.count, max(1, termRows - 2))
            top = scrollTop(top, selected: selected, rows: rows)
            var out = drawn > 0 ? "\u{1B}[\(drawn)A" : ""
            for i in top..<top + rows {
                out += "\r\u{1B}[2K" + line(files[i].lastPathComponent, selected: i == selected, cols: cols) + "\r\n"
            }
            out += "\r\u{1B}[2K" + String("\(selected + 1)/\(files.count)  up/down: move  enter: set  q: cancel"
                .prefix(max(1, cols - 1))) + "\r\n\u{1B}[J"
            put(out)
            drawn = rows + 1
            switch readKey() {
            case .up: selected = max(0, selected - 1)
            case .down: selected = min(files.count - 1, selected + 1)
            case .enter: return files[selected]
            case .cancel: return nil
            case .other: break
            }
        }
    }

    static func put(_ s: String) { sockWrite(STDERR_FILENO, s) }

    static func terminalSize() -> (rows: Int, cols: Int) {
        var ws = winsize()
        guard ioctl(STDERR_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_row > 0, ws.ws_col > 0 else { return (24, 80) }
        return (Int(ws.ws_row), Int(ws.ws_col))
    }

    static func readByte() -> UInt8? {
        var b: UInt8 = 0
        while true {
            let n = read(STDIN_FILENO, &b, 1)
            if n < 0 && errno == EINTR { continue }
            return n == 1 ? b : nil
        }
    }

    /// True when a byte arrives in 50 ms. This tells an arrow key sequence from the Esc key.
    static func hasPendingByte() -> Bool {
        var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, 50) > 0
    }

    static func readKey() -> Key {
        guard let b = readByte() else { return .cancel }
        switch b {
        case 10, 13: return .enter
        case 3, 4, 113: return .cancel  // Ctrl-C, Ctrl-D, q
        case 107, 16: return .up  // k, Ctrl-P
        case 106, 14: return .down  // j, Ctrl-N
        case 27:
            guard hasPendingByte() else { return .cancel }  // Esc key
            guard let b1 = readByte(), b1 == 91 || b1 == 79, let b2 = readByte() else { return .other }
            return b2 == 65 ? .up : b2 == 66 ? .down : .other
        default: return .other
        }
    }
}
