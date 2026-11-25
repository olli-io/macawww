import Foundation

let usageText = """
usage: macpixel <command>
  daemon                                       start the daemon (foreground)
  img <path|dir> [--screen <id|all>] [--fx <name>]
                                               set wallpaper; a directory shows a file list
  <dir> [--screen <id|all>] [--fx <name>]      short form of img <dir>
  rotate <dir> [--screen <id|all>]             rotate through the pixel art in dir
  clear [--color <hex>] [--screen <id|all>] [--fx <name>]
                                               solid colour (default #000000)
  check [<dir>]                                list the images that are not pixel art
  query                                        show screens and state
  pause | resume                               manual pause
  kill                                         stop the daemon
  install | uninstall                          start at login

--fx is the transition: \(FxKind.names). The default is the
`transition` key in the config file, or else burn. The config keys
rotate_interval, random_order and rotate_transition control rotate.
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
    guard State.key(s) != nil else { usage() }
    return s
}

/// The name of the transition. `config`: the daemon uses its config file.
func fxArg(_ o: [String: String]) -> String {
    guard let name = o["fx"] else { return "config" }
    guard FxKind(rawValue: name) != nil else {
        eprint("bad transition \(name): use \(FxKind.names)")
        exit(2)
    }
    return name
}

/// `img <path|dir>`. For a directory, the user selects a file from a list (SPEC §4).
func imgCommand(_ args: ArraySlice<String>) -> Never {
    let (pos, o) = parseArgs(args, options: ["screen", "fx"])
    guard pos.count == 1 else { usage() }
    let screen = screenArg(o), fx = fxArg(o)
    var url = URL(fileURLWithPath: pos[0]).standardizedFileURL
    if Folder.isDirectory(url.path) {
        guard Client.isRunning() else {
            eprint("daemon not running")
            exit(3)
        }
        guard let file = Picker.run(dir: url) else { exit(1) }
        url = file
    }
    exit(Client.send(["img", url.path, screen, fx]))
}

let cliArgs = CommandLine.arguments.dropFirst()
let cliCommand = cliArgs.first ?? ""
let cliRest = cliArgs.dropFirst()

switch cliCommand {
case "daemon":
    guard cliRest.isEmpty else { usage() }
    Daemon.run()
case "img":
    imgCommand(cliRest)
case "rotate":
    let (pos, o) = parseArgs(cliRest, options: ["screen"])
    guard pos.count == 1 else { usage() }
    let screen = screenArg(o)
    let dir = URL(fileURLWithPath: pos[0]).standardizedFileURL.path
    guard Folder.isDirectory(dir) else {
        eprint("not a directory: \(dir)")
        exit(2)
    }
    exit(Client.send(["rotate", dir, screen]))
case "decode":
    // Internal: the daemon starts this as a child process (SPEC §6). Not in the usage text.
    let a = Array(cliRest)
    guard a.count == 2 || (a.count == 3 && a[2] == Decoder.pixelArtFlag) else { usage() }
    Child.main {
        try Decoder.decode(url: URL(fileURLWithPath: a[0]), to: URL(fileURLWithPath: a[1]), pixelArt: a.count == 3)
    }
case "still":
    // Internal: one PNG of frame 0 for the macOS desktop picture (SPEC §16).
    let a = Array(cliRest)
    guard a.count == 4 || a.count == 6, let w = Int(a[2]), let h = Int(a[3]) else { usage() }
    var bar: (px: Int, color: UInt32)?
    if a.count == 6 {
        guard let px = Int(a[4]), (1...h).contains(px), let c = Target.parseColor(a[5]) else { usage() }
        bar = (px, c)
    }
    Child.main {
        try SystemWallpaper.renderStill(cache: URL(fileURLWithPath: a[0]), to: URL(fileURLWithPath: a[1]),
                                        width: w, height: h, bar: bar)
    }
case "still-color":
    let a = Array(cliRest)
    guard a.count == 2, let c = Target.parseColor(a[0]) else { usage() }
    Child.main { try SystemWallpaper.renderColor(c, to: URL(fileURLWithPath: a[1])) }
case "clear":
    let (pos, o) = parseArgs(cliRest, options: ["screen", "color", "fx"])
    guard pos.isEmpty, let c = Target.parseColor(o["color"] ?? "#000000") else { usage() }
    exit(Client.send(["clear", String(format: "%06X", c), screenArg(o), fxArg(o)]))
case "check":
    // Client only: no daemon, no cache file (SPEC §4).
    guard cliRest.count <= 1 else { usage() }
    exit(Check.run(cliRest.first ?? "."))
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
    // Short form: `macpixel <dir>` = `macpixel img <dir>`.
    guard Folder.isDirectory(cliCommand) else { usage() }
    imgCommand(cliArgs)
}
