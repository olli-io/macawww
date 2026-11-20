# macawww

Lean macOS wallpaper manager with animated GIF support. `SPEC.md` is the source of truth. Read it before you change the design.

## Build and test

```
swift build -c release
swift test
```

Builds only on macOS 14+. On Linux: edit only, do not try to build.

## Rules

- No third-party dependencies. System frameworks only (SPEC §14).
- Performance is the main requirement:
  - No allocation, no logging, no Swift collections growth on the tick path.
  - Only the IOSurface writes touch pixel data per frame.
  - Never poll. Use notifications.
  - Do not scale pixels on the CPU.
- All AppKit and CALayer work on the main thread. Decode on a background queue.
- One file per concern (SPEC §14). Keep each file under 300 lines.
- All pause/resume signals go through `Power.swift`.
- Change the cache format → bump the version (SPEC §7).
- Perf change → measure before and after (`top`, `footprint`, `powermetrics`). Give the numbers.
- Design change → update `SPEC.md` in the same commit.
