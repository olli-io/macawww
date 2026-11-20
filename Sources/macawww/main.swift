import Foundation

let usageText = """
usage: macawww <command>
  daemon                                       start the daemon (foreground)
  img <path> [--screen <id|all>]               set wallpaper
  clear [--color <hex>] [--screen <id|all>]    solid colour (default #000000)
  query                                        show screens and state
  pause | resume                               manual pause
  kill                                         stop the daemon
  install | uninstall                          start at login
"""

func usage() -> Never {
    FileHandle.standardError.write(Data((usageText + "\n").utf8))
    exit(2)
}

/// Splits into positional arguments and `--key value` options. Exits on bad options.
func parseArgs(_ args: ArraySlice<String>, options: Set<String>) -> ([String], [String: String]) {
    var pos: [String] = [], opts: [String: String] = [:]
    var it = args.makeIterator()
    while let a = it.next() {
        if a.hasPrefix("--") {
            let k = String(a.dropFirst(2))
            guard options.contains(k), let v = it.next() else { usage() }
            opts[k] = v
        } else {
            pos.append(a)
        }
    }
    return (pos, opts)
}

func screenArg(_ o: [String: String]) -> String {
    let s = o["screen"] ?? "all"
    guard Daemon.targetKey(s) != nil else { usage() }
    return s
}

let cliArgs = CommandLine.arguments.dropFirst()
let cliCommand = cliArgs.first ?? ""
let cliRest = cliArgs.dropFirst()

switch cliCommand {
case "daemon":
    guard cliRest.isEmpty else { usage() }
    Daemon.run()
case "img":
    let (pos, o) = parseArgs(cliRest, options: ["screen"])
    guard pos.count == 1 else { usage() }
    let path = URL(fileURLWithPath: pos[0]).standardizedFileURL.path
    exit(Client.send(["img", path, screenArg(o)]))
case "decode":
    // Internal: the daemon starts this as a child process (SPEC §6). Not in the usage text.
    let a = Array(cliRest)
    guard a.count == 2 else { usage() }
    Child.main { try Decoder.decode(url: URL(fileURLWithPath: a[0]), to: URL(fileURLWithPath: a[1])) }
case "still":
    // Internal: one PNG of frame 0 for the macOS desktop picture (SPEC §16).
    let a = Array(cliRest)
    guard a.count == 4, let w = Int(a[2]), let h = Int(a[3]) else { usage() }
    Child.main {
        try SystemWallpaper.renderStill(cache: URL(fileURLWithPath: a[0]), to: URL(fileURLWithPath: a[1]),
                                        width: w, height: h)
    }
case "still-color":
    let a = Array(cliRest)
    guard a.count == 2, let c = Target.parseColor(a[0]) else { usage() }
    Child.main { try SystemWallpaper.renderColor(c, to: URL(fileURLWithPath: a[1])) }
case "clear":
    let (pos, o) = parseArgs(cliRest, options: ["screen", "color"])
    guard pos.isEmpty, let c = Target.parseColor(o["color"] ?? "#000000") else { usage() }
    exit(Client.send(["clear", String(format: "%06X", c), screenArg(o)]))
case "query", "pause", "resume", "kill":
    guard cliRest.isEmpty else { usage() }
    exit(Client.send([cliCommand]))
case "install":
    guard cliRest.isEmpty else { usage() }
    exit(LaunchAgent.install())
case "uninstall":
    guard cliRest.isEmpty else { usage() }
    exit(LaunchAgent.uninstall())
case "help", "-h", "--help":
    print(usageText)
    exit(0)
default:
    usage()
}
