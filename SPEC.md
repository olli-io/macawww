# macpixel specification

macpixel is a purist pixel art wallpaper engine for macOS. It shows static images and animated GIFs on the desktop. It uses the minimum CPU, memory and power.

This file is the source of truth for the design.

## 1. Goal and non-goals

Goal: the lowest CPU, RAM and power use for an animated wallpaper.

Non-goals (v1):
- GUI or menu bar item.
- Playlists, slideshows. Transitions other than those of §17.
- Video input (see §15).
- App bundle. macpixel is one CLI binary.

## 2. Targets

| Item | Target |
|---|---|
| OS | macOS 14+. Apple silicon only. |
| Static image, idle | 0 % CPU, < 25 MB RSS |
| 4K GIF, small diffs | < 1 % CPU on M1, < 40 MB RSS |
| Paused | 0 wakeups from macpixel |
| Binary size | < 1 MB (release, stripped) |

## 3. Architecture

One Swift binary with two roles:

- **Daemon** (`macpixel daemon`): owns the windows, the cache, the players and the pause logic. Runs `NSApplication` with activation policy `.accessory` (no Dock icon, no menu bar).
- **Client** (all other subcommands): sends one command to the daemon and prints the reply.

IPC: Unix domain socket at `$TMPDIR/macpixel.sock` (`NSTemporaryDirectory()`, mode 0600). Protocol: JSON Lines. One connection per command: the client sends one line, the daemon sends one line, then closes. JSON escapes all control characters, so paths with spaces, tabs or newlines are safe.

- Request: JSON array of strings, the subcommand and its arguments. `["img","/path/a b.gif","all","config"]`, `["clear","000000","all","wipe"]`, `["query"]`, `["pause"]`, `["resume"]`, `["kill"]`.
  The last argument of `img` and `clear` is the transition name of §17, or `config`.
- Reply: JSON object. `{"ok":true}` or `{"ok":false,"error":"<message>"}`.
- `query` reply: `{"ok":true,"screens":[{"id":1,"width":3840,"height":2160,"file":"/a.gif","state":"paused","reasons":["occluded"]}]}`. A screen has `file` or `color` (`"#RRGGBB"`). `state` is `playing`, `paused`, `static` or `stopped` (loop count done). `reasons` is present only when `paused`.

The client prints `query` as one text line per screen: `<id> <w>x<h> <file|color #RRGGBB> <state>[ (<reasons>)]`.

Data flow:

```
file ──ImageIO──▶ Decoder ──diff+LZ4──▶ cache file (.mcw)
                                            │ mmap
                                            ▼
                     Power ──paused?──▶ Player ──IOSurface──▶ CALayer (one per screen)
```

One `Player` per distinct file. All screens that show the same file share one `Player` and one pair of IOSurfaces.

## 4. CLI

| Command | Action |
|---|---|
| `macpixel daemon` | Start the daemon (foreground). |
| `macpixel img <path> [--screen <id\|all>] [--fx <name>]` | Set wallpaper. Default `all`. `--fx`: see §17. |
| `macpixel img <dir> [--screen <id\|all>] [--fx <name>]` | Show a list of the images in `<dir>`. Set the selected one. |
| `macpixel <dir> [--screen <id\|all>] [--fx <name>]` | Short form of `img <dir>`. A command name has priority over a directory with the same name. |
| `macpixel clear [--color <hex>] [--screen ...] [--fx ...]` | Solid colour. Default `#000000`. |
| `macpixel check [<dir>]` | One line for each image of the directory that is not pixel art (N = 1, §6 step 5) or that fails to decode: `<path>: <reason>`. Default: the current directory. Not recursive. A file path checks that file only. The files are those of the file list below. The client does this (`Check.swift`), without the daemon and without a cache file. Exit code 1 when a line is printed. |
| `macpixel query` | Print screens, size, file, state (playing/paused + reason). |
| `macpixel pause` / `resume` | Manual pause. |
| `macpixel kill` | Stop the daemon. |
| `macpixel install` / `uninstall` | Start at login (see §12). |

`<id>` is the `CGDirectDisplayID`, as `query` shows it.

Exit codes: 0 = ok, 1 = error or cancel, 2 = usage error, 3 = daemon not running.

File list (`Picker.swift`): the files in `<dir>` with the extension `.gif`, `.png`, `.jpg` or `.jpeg` (case ignored), in Finder name order. Hidden files and subdirectories are not shown. Keys: up/down or `k`/`j` move, Enter sets the wallpaper, `q`, Esc or Ctrl-C cancel (exit 1). Keys come from stdin and the list goes to stderr, so both must be a terminal. The list scrolls when it is longer than the terminal. The client checks for the daemon before it shows the list.

`--screen all` replaces all per-screen states. `macpixel daemon` when a daemon already runs: message, exit 0 (so launchd does not restart it).

## 5. Wallpaper window

One window per screen:
- Borderless `NSWindow`, frame = `screen.frame`.
- Level `CGWindowLevelForKey(.desktopWindow)`. Desktop icons stay above.
- `ignoresMouseEvents = true`, `isOpaque = true`, `hasShadow = false`.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`.
- Content view is layer-hosting. The root layer is black and has `masksToBounds = true`. It has one image sublayer:
  - `frame` = the root bounds, `contentsGravity = .resizeAspectFill` (see "Integer scale" for pixel art)
  - `magnificationFilter = .nearest`, `minificationFilter = .linear`
  - `contents` = the `Player`'s front IOSurface.

### Scaling

Do not filter or resample at load. The window server scales during composition, which it does in all cases. Nearest filter keeps pixel art sharp and keeps diffs small. A 4K GIF on a 4K screen has no scale.

One exception: an image that is an integer upscale of smaller art (each aligned N×N block has one colour) is stored at 1/N size (§6 step 5). This is a point sample with no loss. The window server shows the same picture, and the buffers are N² times smaller.

### Integer scale

Pixel art (cache flag `pixelArt`, §7) shows at a whole-number scale, so that all art pixels have the same size. Each screen calculates its own scale from its size in backing pixels (`frame` × `backingScaleFactor`):

- k = the smallest whole number where art × k covers the screen: `max(ceil(W / w), ceil(H / h))`.
- The image layer has `contentsGravity = .resize` and the size art × k pixels. It is centred on whole pixels. The root layer cuts the part outside the screen.
- k is never less than 1. There is no fallback to aspect fill: the overflow is always cut, as in pixelwp. Thus the screen shows a part of the art of `ceil(W / k)` × `ceil(H / k)` art pixels, and the nearest filter scales it by exactly k.
- Calculate again when the image, the screen frame or the backing scale changes (§10).

Limit: in a scaled display mode, macOS scales the backing buffer to the panel after composition. Then the art pixels are equal in the buffer, but not on the panel.

## 6. Decode and cache

Input formats: all formats that ImageIO reads. Multi-frame GIF, APNG and WebP animate. All others are one frame.

Max size: 16384 px per side (IOSurface limit). A still image that is larger is scaled down once at decode; a larger animation is an error. Still images use `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailWithTransform`, so the EXIF orientation applies.

The daemon does not decode. On a cache miss it starts `macpixel decode <src> <dst>` (the same binary, an internal command, see `Child.swift`) as a child process, waits for it on the background queue, then maps the cache file. All decode memory (ImageIO, frame buffers, malloc caches) goes away with the child. The child writes its error text to stderr and exits with status 1; the daemon puts that text in the `err` reply.

Steps (step 1 in the daemon on the background queue, the others in the child; one frame in memory at a time, plus the previous frame, plus one source-size frame when step 5 finds an upscale):
1. Hash the file bytes (SHA-256, CryptoKit). If a valid cache file exists, skip to §8.
2. `CGImageSourceCreateWithURL`. Read frame count, loop count, and the delay per frame (`kCGImagePropertyGIFUnclampedDelayTime`, fall back to `DelayTime`).
3. Clamp: a delay < 20 ms becomes 100 ms (browser behaviour).
4. For each frame: `CGImageSourceCreateImageAtIndex` gives the composited frame. Draw it into a BGRA premultiplied buffer of the source size.
5. Integer upscale: N = the GCD of all run lengths of equal pixels along the rows and columns of frame 0. If N > 1, store one pixel per N×N block; all later steps use the small frame. Check each later frame against N. If a frame fails, calculate the smaller N (a divisor of the old N) and start the decode again. If N = 1, there is no extra buffer and no extra copy.
6. Compare with the previous frame in 32×32 tiles (`memcmp` per tile row). Mark changed tiles.
7. Merge changed tiles into at most 8 rects (row runs, then vertical merge, then bounding-box merge of the smallest pairs until ≤ 8).
8. If the dirty area > 50 % of the frame, store one full-frame rect.
9. Frame 0 is always a full frame.
10. Compress each rect with LZ4 (`compression_encode_buffer`, `COMPRESSION_LZ4_RAW`).
11. Append to the cache file. Release the frame.
12. Write to a temp file, `fsync`, then `rename` to the final name.

Identical consecutive frames: merge them into one entry and add the delays.

## 7. Cache file format (`.mcw`)

Path: `~/Library/Caches/macpixel/<sha256-hex>.mcw`. Little-endian.

```
Header (32 bytes)
  u32 magic      'MCWW'
  u16 version    3
  u16 flags      bit 0 = pixelArt (step 5 of §6 found N > 1). Other bits: 0.
  u32 width
  u32 height
  u32 frameCount
  u32 loopCount  0 = forever
  u64 indexOffset

Payload (per frame, per rect)
  LZ4 bytes, 16-byte aligned

Index (at indexOffset), frameCount entries
  u32 delayMs
  u32 rectCount
  rectCount × { u16 x, u16 y, u16 w, u16 h, u64 offset, u32 size }
```

Read: `mmap` the whole file, `PROT_READ`, `MAP_PRIVATE`. The pages are file-backed and clean, so the kernel can evict them under pressure. Validate magic, version and bounds before use. On a bad file: delete it and decode again.

Eviction: LRU by access time when the cache dir is larger than `max_cache_mb`. It includes the PNG files of §16. Files in use stay.

Bump `version` on any format change.

## 8. Playback

Two IOSurfaces at source size, BGRA, `kIOSurfaceIsGlobal` off. Names: `front` (on screen) and `back`.

Invariant: before the tick that shows frame `k`, `back` holds frame `k-2` (mod frameCount).

On a tick for frame `k`:
1. Lock `back`. If the lock fails, schedule a retry in 16 ms and stop this tick.
   If diff `k` is a full frame: decompress it into `back`. Otherwise copy the rects of diff `k-1` from `front` (which holds frame `k-1`) into `back` (`memcpy`, no decode), then decompress diff `k` into `back`. Decompress straight into the locked surface rows (`compression_decode_buffer` per row block; no temp buffer for full-width rects).
2. Unlock `back`.
3. In a `CATransaction` with actions disabled: set `layer.contents = back` for all layers of this player.
4. Swap `front` and `back`.
5. Schedule the next tick with the delay of frame `k`.

The invariant holds at loop wrap because frame 0 is full.

Timer: one `DispatchSourceTimer` per player on the main queue, leeway = 10 % of the delay. The timer fires once per frame and reschedules itself. No allocation on a tick.

When the invariant breaks (resume, new screen, wake): mark the player unsynced. The next tick copies `front` into `back` (one `memcpy`, skipped when diff `k` is full), then applies diff `k` only. After that tick, the invariant holds again.

Temp buffer: a rect decodes straight into the surface when it is full-width and the surface stride is `width × 4`. Other rects decode into one temp buffer, then copy row by row. The player allocates this buffer once, at the size of the largest such rect. IOSurface stride comes from `IOSurfaceAlignProperty`, so narrow images can have padded rows.

The surfaces are tagged sRGB (`IOSurfaceColorSpace`), the same space the decoder draws in.

Static image (1 frame): fill `front` once, set `contents`, no timer, no `back` surface. Then release the mmap and the decode buffers.

`loopCount > 0`: stop on the last frame after the last loop. Then release `back`, the mmap and the decode buffers, as for a static image.

Pause: set `back` to `kIOSurfacePurgeableVolatile`. The kernel can take its pages. Resume: set it non-volatile. The content of `back` is not necessary, because the player is unsynced after a resume.

## 9. Pause rules

`Power` keeps one set of pause reasons. A player runs only when the set is empty for it. Reasons:

| Reason | Signal | Scope |
|---|---|---|
| `occluded` | `NSWindow.didChangeOcclusionStateNotification`; paused when all windows of the player are not visible | per player |
| `displaySleep` | `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification` | global |
| `systemSleep` | `NSWorkspace.willSleepNotification` / `didWakeNotification` | global |
| `locked` | distributed `com.apple.screenIsLocked` / `screenIsUnlocked` | global |
| `sessionInactive` | `NSWorkspace.sessionDidResignActiveNotification` / `didBecomeActive` | global |
| `lowPower` | `NSProcessInfoPowerStateDidChange`, `isLowPowerModeEnabled` | global |
| `user` | `pause` / `resume` commands | global |

The power source (battery or charger) is not a pause reason. On battery, only Low Power Mode pauses the players.

On pause: cancel the timer. Keep the current frame on screen. Make `back` volatile (§8).
On resume: restore the invariant (§8), then start the timer.

Open point: the occlusion state of a desktop-level window can stay "visible" when a full-screen app covers it. Verify on macOS 14 and 15. Fallback (implemented): on `NSWorkspace.activeSpaceDidChangeNotification`, do one `CGWindowListCopyWindowInfo` check for a layer-0 window of another process with bounds equal to the display bounds, then one more check 600 ms later (after the space animation). A covered display counts as not visible. Never poll.

## 10. Display changes

Signals: `NSApplication.didChangeScreenParametersNotification`, `NSWorkspace.didWakeNotification`, `screensDidWakeNotification`.

Debounce 250 ms, then reconcile by `CGDirectDisplayID`:
- New screen: create a window. Use the per-screen state, else the `all` state.
- Gone screen: close the window. Release the player when it has no layers.
- Changed frame or backing scale: `setFrame(screen.frame, display: false)`, then set the image layer frame again (§5).

Then restore the invariant (§8) for each player that changed.

## 11. State and config

Dir: `~/Library/Application Support/macpixel/`.

- `state`: one line per target, `<id|all> img <path>` or `<id|all> color <hex>`. Written on each change (temp file + rename). Read at daemon start.
- `config` (optional, `key = value`):
  - `max_cache_mb` (int, default `512`)
  - `transition` (`burn`, `sweep`, `slide`, `wipe` or `disabled`, default `burn`; see §17)

The daemon reads `config` one time, at start.

## 12. Start at login

`install`:
1. Write `~/Library/LaunchAgents/io.macpixel.daemon.plist`:
   - `Label` = `io.macpixel.daemon`
   - `ProgramArguments` = absolute binary path, `daemon`
   - `RunAtLoad` = true
   - `KeepAlive` = `{ SuccessfulExit = false }` (restart on crash only)
   - `ProcessType` = `Interactive`
   - `StandardErrorPath` = `~/Library/Logs/macpixel.log`
2. `launchctl bootstrap gui/$UID <plist>`.

`uninstall`: `launchctl bootout gui/$UID/io.macpixel.daemon`, then delete the plist.

## 13. Errors and logs

- Client: one-line message on stderr, exit code per §4.
- Daemon: `os_log`, subsystem `io.macpixel`. No log on the tick path.
- Decode error: keep the old wallpaper, reply `err`.

## 14. Source layout

```
Package.swift
Sources/macpixel/
  main.swift          CLI parse, dispatch
  Daemon.swift        app setup, socket server, state file
  Config.swift        config file
  Client.swift        socket client
  Picker.swift        file list for `img <dir>`
  Screens.swift       window per screen, reconcile
  Decoder.swift       ImageIO → frame encoder → cache writer
  Diff.swift          tile diff, rect merge
  Upscale.swift       integer upscale detection, point sample
  Check.swift         `check`: list the images that are not pixel art
  Cache.swift         file format, mmap reader, eviction
  Player.swift        IOSurface double buffer, timer
  Power.swift         pause signals → pause reasons
  Fx.swift            transitions: cell grid, burn, sweep, wipe, slide timing
  Transition.swift    transitions: layers, grid surface, step timer
  SystemWallpaper.swift  macOS desktop picture sync, still PNG
  Child.swift         child process for internal commands
  LaunchAgent.swift   install / uninstall
Tests/macpixelTests/
```

Frameworks: AppKit, QuartzCore, ImageIO, IOSurface, Compression, CryptoKit. No third-party dependencies.

### Tests

Unit:
- Diff + LZ4 round trip gives each frame bit-exact (synthetic frames and fixture GIFs).
- Cache write/read; bad magic, bad version, truncated file are rejected.
- Delay clamp; identical-frame merge.
- Integer upscale: factor, block check, point sample, decode restart with a smaller factor.
- `check`: factor of a PNG, factor over all frames, list of a directory, exit code.
- Integer scale per screen: k for exact fit, for cut, and for art larger than the screen.
- Still PNG for the macOS desktop picture: size, scale and cut are equal to the layer.
- Double-buffer invariant over 3 loops, including 1, 2 and 3 frame animations.
- Transitions: gradients, burn order, start and end of each kind, grid pixels, slide timing, grid placement.

Manual (macOS):
- Hotplug, resolution change, mirror on/off.
- Sleep/wake, lock/unlock, fast user switch.
- Spaces, full-screen app, Mission Control.
- Battery unplug (no pause), Low Power Mode (pause).
- macOS desktop picture: follows `img` and `clear`, each Space after a visit, lock screen.
- Transitions: each kind, image ↔ colour, pixel art ↔ other image, two screens, `pause` during a transition.
- Measure with `top -pid`, `footprint`, `sudo powermetrics --samplers tasks`.

## 15. Open points

1. Occlusion of desktop-level windows (§9).
2. IOSurface lock cost at 4K. Measure. If high, use `kIOSurfaceLockAvoidSync`.
3. Video input: MP4/HEVC through `AVPlayerLayer` uses the hardware decoder. Possible lower power for high-motion clips. Not in v1.

## 16. macOS desktop picture

The macpixel window covers the desktop only while the daemon runs. The daemon also sets the macOS desktop picture of each screen to the same content, so that macOS shows it where the window is not present (before the daemon starts, after `kill`, on the lock screen). Always on. There is no option.

For each screen, after its image, colour, frame or backing scale changed (the `onLayout` callback of `Screens`):

| Content | File for macOS | macOS scaling |
|---|---|---|
| Pixel art at an integer scale (§5) | `<cache dir>/<sha256>-<W>x<H>.png`: frame 0 at the screen size in pixels, with the scale and the cut of the layer. No filter. | none necessary (file size = screen size) |
| Other image | the original file | proportional, clipping allowed (aspect fill) |
| Colour | `<cache dir>/color-<RRGGBB>.png`, 16×16 | axes independent |

- A missing PNG is made by a child process (`macpixel still <mcw> <png> <W> <H>`, `macpixel still-color <hex> <png>`), as in §6. The daemon does not load ImageIO.
- The call is `NSWorkspace.setDesktopImageURL(_:for:options:)`. Skip it when `desktopImageURL(for:)` already gives the same path.
- macOS shows the first frame only. Animation stays in the macpixel window.
- Spaces: the macOS call changes the active Space only. On `NSWorkspace.activeSpaceDidChangeNotification`, set the picture again for each screen. Thus each Space gets the picture when the user goes to it. No public API sets all Spaces in one operation. Never poll.
- Lock screen: macOS uses the desktop picture there. There is no separate call.
- macpixel does not store the desktop picture that it replaces. `uninstall` and `kill` leave the last picture.

## 17. Transitions

`img` and `clear` show the change with a transition. The transitions are the effects of ttfx, as in pixelwp, changed to pixel-art cells. A restore (daemon start, new screen, reload after a cache miss) has no transition.

- **Selection:** `--fx <burn|sweep|slide|wipe|disabled>`. Without `--fx`, the client sends `config` and the daemon uses the `transition` key (§11). The default is `burn`.
- **Grid:** 540 × 270 cells. Each screen shows it at the smallest whole-number scale that covers the screen (`max(ceil(W / 540), ceil(H / 270))`), centred on whole pixels. The overflow is cut.
- **Step:** 33 ms. One repeating `DispatchSourceTimer` on the main queue for the transition. It exists only during the transition.
- **Burn:** a fire starts at a random cell and spreads in the order of a random spanning tree (the simple Prim's algorithm), in approximately 60 steps. A cell burns for 11 steps (`FFFFFF` … `510100`), then shows the new wallpaper. One of 64 cells emits smoke, which rises for 16 steps.
- **Sweep:** one pass. A shimmer of random colours (`8A008A` … `FFFFFF`) goes from left to right in 40 steps (`inOutQuad`) and leaves the new wallpaper. A cell shimmers for 4 steps. pixelwp has a first pass that leaves the old wallpaper in grey; macpixel does not.
- **Wipe:** the diagonals `x + y = d` start in 50 steps (`inOutQuad`), from the top left. A cell shows the colours `833AB4` … `FCB045` for 4 steps, then the new wallpaper.
- **Slide:** bands of 6 rows. Band `b` starts at step `b + 1` and moves for 24 steps (`inOutQuad`). It shows the new wallpaper moved to the left, with its right edge at the band edge.

Composition (the window server does all scaling and mixing; macpixel writes no wallpaper pixels):

- `Screens.show` puts the new wallpaper on the image layer at once. Above it, each screen gets a temporary layer with:
  - a copy of the image layer as it was before the change (the old wallpaper). It is a layer of the old player, so the old animation continues. The transition keeps the old player until its end.
  - burn, sweep, wipe: the grid layers. One pair of IOSurfaces (`front`, `back`) of 1080 × 270 holds the grid: the left half is the colour of each cell (transparent when the cell shows a wallpaper), the right half is the mask of the old wallpaper (alpha 0 when the cell shows the new one). Two layers show the halves with `contentsRect` and the nearest filter: one is the mask of the old copy, one is above it. All screens share the surfaces.
  - slide: no grid. One clip layer for each band, with a copy of the new image layer (a layer of the new player). A step sets the clip width and the copy position of the bands that move.
- On a step, for burn, sweep and wipe: advance the cells, write the full grid into `back` (291 600 pixels), set `contents` of the grid layers, swap. No allocation, no logging.
- At the end: remove the temporary layers, release the surfaces, the grid (approximately 4 MB in total) and the old player.

Rules:

- One transition at a time. A new `img` or `clear`, and each display change (§10), ends the current transition at once.
- A transition does not pause. It ends at once when a pause reason (§9) is active for all its screens, and it does not start in that condition. Thus a paused daemon has no wakeups.
- A screen whose wallpaper did not change has no transition.
