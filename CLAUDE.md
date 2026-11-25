# macpixel

Purist pixel art wallpaper engine for macOS, with animated GIF support. `SPEC.md` is the source of truth. Read it before you change the design.

## Build and test

```
swift build -c release
swift test
bin/build-saver        # the screensaver bundle (SPEC §18)
```

Builds only on macOS 14+. Apple silicon only. On Linux: edit only, do not try to build.

## Rules

- No third-party dependencies. System frameworks only (SPEC §14).
- Performance is the main requirement:
  - No allocation, no logging, no Swift collections growth on the tick path.
  - Only the IOSurface writes touch pixel data per frame.
  - Never poll. Use notifications.
  - Do not scale pixels on the CPU. One exception: the point sample of an integer upscale at decode (SPEC §6 step 5).
- All AppKit and CALayer work on the main thread. Decode on a background queue.
- One file per concern (SPEC §14). Keep each file under 300 lines.
- All pause/resume signals go through `Power.swift`.
- A file of `Sources/macpixel/` that the screensaver uses (the `SHARED` list in `bin/build-saver`) must not use the daemon or AppKit windows.
- Change the cache format → bump the version (SPEC §7).
- Perf change → measure before and after (`top`, `footprint`, `powermetrics`). Give the numbers.
- Design change → update `SPEC.md` in the same commit.
