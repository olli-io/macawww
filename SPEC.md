# macawww specification

macawww is a wallpaper manager for macOS. It shows static images and animated GIFs on the desktop. It uses the minimum CPU, memory and power.

This file is the source of truth for the design.

## 1. Goal and non-goals

Goal: the lowest CPU, RAM and power use for an animated wallpaper.

Non-goals (v1):
- GUI or menu bar item.
- Playlists, slideshows, transitions.
- Video input (see §15).
- App bundle. macawww is one CLI binary.

## 2. Targets

| Item | Target |
|---|---|
| OS | macOS 14+. Apple Silicon first. Intel must work. |
| Static image, idle | 0 % CPU, < 25 MB RSS |
| 4K GIF, small diffs | < 1 % CPU on M1, < 40 MB RSS |
| Paused | 0 wakeups from macawww |
| Binary size | < 1 MB (release, stripped) |

## 3. Architecture

One Swift binary with two roles:

- **Daemon** (`macawww daemon`): owns the windows, the cache, the players and the pause logic. Runs `NSApplication` with activation policy `.accessory` (no Dock icon, no menu bar).
- **Client** (all other subcommands): sends one command to the daemon and prints the reply.

IPC: Unix domain socket at `$TMPDIR/macawww.sock` (`NSTemporaryDirectory()`, mode 0600). Protocol: JSON Lines. One connection per command: the client sends one line, the daemon sends one line, then closes. JSON escapes all control characters, so paths with spaces, tabs or newlines are safe.

- Request: JSON array of strings, the subcommand and its arguments. `["img","/path/a b.gif","all"]`, `["clear","000000","all"]`, `["query"]`, `["pause"]`, `["resume"]`, `["kill"]`.
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
| `macawww daemon` | Start the daemon (foreground). |
| `macawww img <path> [--screen <id\|all>]` | Set wallpaper. Default `all`. |
| `macawww clear [--color <hex>] [--screen ...]` | Solid colour. Default `#000000`. |
| `macawww query` | Print screens, size, file, state (playing/paused + reason). |
| `macawww pause` / `resume` | Manual pause. |
| `macawww kill` | Stop the daemon. |
| `macawww install` / `uninstall` | Start at login (see §12). |

`<id>` is the `CGDirectDisplayID`, as `query` shows it.

Exit codes: 0 = ok, 1 = daemon error, 2 = usage error, 3 = daemon not running.

`--screen all` replaces all per-screen states. `macawww daemon` when a daemon already runs: message, exit 0 (so launchd does not restart it).

## 5. Wallpaper window

One window per screen:
- Borderless `NSWindow`, frame = `screen.frame`.
- Level `CGWindowLevelForKey(.desktopWindow)`. Desktop icons stay above.
- `ignoresMouseEvents = true`, `isOpaque = true`, `hasShadow = false`.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`.
- Content view is layer-backed. The layer:
  - `contentsGravity = .resizeAspectFill`
  - `magnificationFilter = .nearest`, `minificationFilter = .linear`
  - `contents` = the `Player`'s front IOSurface.

### Scaling

Do not scale at load. The buffer stays at the source size. The window server scales during composition, which it does in all cases. Nearest filter keeps pixel art sharp and keeps diffs small. A 4K GIF on a 4K screen has no scale.

## 6. Decode and cache

Input formats: all formats that ImageIO reads. Multi-frame GIF, APNG and WebP animate. All others are one frame.

Max size: 16384 px per side (IOSurface limit). A still image that is larger is scaled down once at decode; a larger animation is an error. Still images use `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailWithTransform`, so the EXIF orientation applies.

Steps (background queue, one frame in memory at a time, plus the previous frame):
1. Hash the file bytes (SHA-256, CryptoKit). If a valid cache file exists, skip to §8.
2. `CGImageSourceCreateWithURL`. Read frame count, loop count, and the delay per frame (`kCGImagePropertyGIFUnclampedDelayTime`, fall back to `DelayTime`).
3. Clamp: a delay < 20 ms becomes 100 ms (browser behaviour).
4. For each frame: `CGImageSourceCreateImageAtIndex` gives the composited frame. Draw it into a BGRA premultiplied buffer of the source size.
5. Compare with the previous frame in 32×32 tiles (`memcmp` per tile row). Mark changed tiles.
6. Merge changed tiles into at most 8 rects (row runs, then vertical merge, then bounding-box merge of the smallest pairs until ≤ 8).
7. If the dirty area > 50 % of the frame, store one full-frame rect.
8. Frame 0 is always a full frame.
9. Compress each rect with LZ4 (`compression_encode_buffer`, `COMPRESSION_LZ4_RAW`).
10. Append to the cache file. Release the frame.
11. Write to a temp file, `fsync`, then `rename` to the final name.

Identical consecutive frames: merge them into one entry and add the delays.

## 7. Cache file format (`.mcw`)

Path: `~/Library/Caches/macawww/<sha256-hex>.mcw`. Little-endian.

```
Header (32 bytes)
  u32 magic      'MCWW'
  u16 version    1
  u16 flags      0
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

Eviction: LRU by access time when the cache dir is larger than `max_cache_mb`.

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
| `battery` | `IOPSNotificationCreateRunLoopSource`; only if `pause_on_battery = true` | global |
| `user` | `pause` / `resume` commands | global |

On pause: cancel the timer. Keep the current frame on screen. Make `back` volatile (§8).
On resume: restore the invariant (§8), then start the timer.

Open point: the occlusion state of a desktop-level window can stay "visible" when a full-screen app covers it. Verify on macOS 14 and 15. Fallback (implemented): on `NSWorkspace.activeSpaceDidChangeNotification`, do one `CGWindowListCopyWindowInfo` check for a layer-0 window of another process with bounds equal to the display bounds, then one more check 600 ms later (after the space animation). A covered display counts as not visible. Never poll.

## 10. Display changes

Signals: `NSApplication.didChangeScreenParametersNotification`, `NSWorkspace.didWakeNotification`, `screensDidWakeNotification`.

Debounce 250 ms, then reconcile by `CGDirectDisplayID`:
- New screen: create a window. Use the per-screen state, else the `all` state.
- Gone screen: close the window. Release the player when it has no layers.
- Changed frame: `setFrame(screen.frame, display: false)`.

Then restore the invariant (§8) for each player that changed.

## 11. State and config

Dir: `~/Library/Application Support/macawww/`.

- `state`: one line per target, `<id|all> img <path>` or `<id|all> color <hex>`. Written on each change (temp file + rename). Read at daemon start.
- `config` (optional, `key = value`):
  - `pause_on_battery` (bool, default `true`)
  - `max_cache_mb` (int, default `512`)

## 12. Start at login

`install`:
1. Write `~/Library/LaunchAgents/io.macawww.daemon.plist`:
   - `Label` = `io.macawww.daemon`
   - `ProgramArguments` = absolute binary path, `daemon`
   - `RunAtLoad` = true
   - `KeepAlive` = `{ SuccessfulExit = false }` (restart on crash only)
   - `ProcessType` = `Interactive`
   - `StandardErrorPath` = `~/Library/Logs/macawww.log`
2. `launchctl bootstrap gui/$UID <plist>`.

`uninstall`: `launchctl bootout gui/$UID/io.macawww.daemon`, then delete the plist.

## 13. Errors and logs

- Client: one-line message on stderr, exit code per §4.
- Daemon: `os_log`, subsystem `io.macawww`. No log on the tick path.
- Decode error: keep the old wallpaper, reply `err`.

## 14. Source layout

```
Package.swift
Sources/macawww/
  main.swift          CLI parse, dispatch
  Daemon.swift        app setup, socket server, state file
  Client.swift        socket client
  Screens.swift       window per screen, reconcile
  Decoder.swift       ImageIO → diff → cache writer
  Cache.swift         file format, mmap reader, eviction
  Player.swift        IOSurface double buffer, timer
  Power.swift         pause signals → pause reasons
  LaunchAgent.swift   install / uninstall
Tests/macawwwTests/
```

Frameworks: AppKit, QuartzCore, ImageIO, IOSurface, Compression, IOKit, CryptoKit. No third-party dependencies.

### Tests

Unit:
- Diff + LZ4 round trip gives each frame bit-exact (synthetic frames and fixture GIFs).
- Cache write/read; bad magic, bad version, truncated file are rejected.
- Delay clamp; identical-frame merge.
- Double-buffer invariant over 3 loops, including 1, 2 and 3 frame animations.

Manual (macOS):
- Hotplug, resolution change, mirror on/off.
- Sleep/wake, lock/unlock, fast user switch.
- Spaces, full-screen app, Mission Control.
- Battery unplug, Low Power Mode.
- Measure with `top -pid`, `footprint`, `sudo powermetrics --samplers tasks`.

## 15. Open points

1. Occlusion of desktop-level windows (§9).
2. IOSurface lock cost at 4K. Measure. If high, use `kIOSurfaceLockAvoidSync`.
3. Video input: MP4/HEVC through `AVPlayerLayer` uses the hardware decoder. Possible lower power for high-motion clips. Not in v1.
