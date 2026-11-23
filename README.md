# macpixel

> [!IMPORTANT]
> **macpixel is a purist pixel art wallpaper engine for macOS.**
> It runs only on Apple silicon Macs, with macOS 14 or later.
> To keep it minimal, lightweight and true, no features will be added.

> [!NOTE]
> macpixel shows only true pixel art pixel-perfect: an N× integer upscale (N ≥ 2).
> All other images fill the screen at a scale that is not a whole number.
> `macpixel check <dir>` lists the images in a folder that are not pixel art.

Performance features:
- **Small files.** Pixel art is automatically downscaled and cached at 1x size. Only the pixels that change between frames are saved.
- **Low memory.** A separate process decodes the image and then exits. The daemon keeps only the optimized cache.
- **Low CPU.** On each frame, only the changed regions are written. The animation stops when the wallpaper is not visible.
- **Fast runtime scale to target resolution.** Pixel art needs no filters, only nearest scaling.

The full design is in [SPEC.md](SPEC.md).

## Install

Requirements: an Apple silicon Mac and macOS 14 or later.

```sh
curl -fsSL https://raw.githubusercontent.com/olli-io/macpixel/main/install.sh | sh
```

The script does these steps:

1. It downloads the latest released binary and makes sure that its checksum is correct.
2. It copies the binary to `~/.local/bin/macpixel`.
3. It runs `macpixel install`, which starts the daemon now and at each login.

Read the script before you run it: [install.sh](install.sh).

To give options with curl, use `sh -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/olli-io/macpixel/main/install.sh | sh -s -- --version v1.0.0
```

| Option | Function |
|---|---|
| `--bin-dir <dir>` | Put the binary in `<dir>`. The default is `~/.local/bin`. |
| `--version <vX.Y.Z>` | Install this release. The default is the latest release. |
| `--no-agent` | Copy the binary only. Do not start the daemon at login. |

To update, run the script again. It stops the old daemon, replaces the binary and starts the new daemon. Your wallpapers stay.

To remove macpixel, run `macpixel uninstall`, then delete the binary.

## Build

Requirements: an Apple silicon Mac, macOS 14 or later, and Swift 5.9 or later (Xcode or the Command Line Tools).

```sh
git clone https://github.com/olli-io/macpixel
cd macpixel
swift build -c release
```

The binary is `.build/release/macpixel`. Copy it to a directory in your `PATH`, then start the daemon:

```sh
cp .build/release/macpixel ~/.local/bin/
macpixel install
```

To run the tests:

```sh
swift test
```

A push of a tag `vX.Y.Z` makes a release: GitHub Actions runs the tests on macOS 14 and 15, builds the arm64 binary, and publishes it ([build.yml](.github/workflows/build.yml)).

## Quick start

1. Start the daemon at login. This command also starts it now. The install script already does this step.

   ```sh
   macpixel install
   ```

2. Set a wallpaper.

   ```sh
   macpixel img ~/Pictures/wallpaper.gif
   ```

3. Look at the state.

   ```sh
   macpixel query
   ```

   ```
   1 1470x956 /Users/me/Pictures/wallpaper.gif playing
   ```

`install` writes the absolute path of the binary into the launch agent. Copy the binary to its final location before you run `install`. If you move the binary later, run `macpixel uninstall`, then `macpixel install` again.

To try macpixel without the launch agent, run `macpixel daemon` in a terminal. It stays in the foreground.

## Commands

| Command | Function |
|---|---|
| `macpixel daemon` | Start the daemon in the foreground. |
| `macpixel img <path> [--screen <id\|all>] [--fx <name>]` | Set an image as wallpaper. The default screen is `all`. `--fx`: see [Transitions](#transitions). |
| `macpixel <dir>` or `macpixel img <dir>` | Show a list of the `.gif`, `.png` and `.jpg` files in the directory. Select one with the arrow keys and Enter. `q` cancels. |
| `macpixel clear [--color <hex>] [--screen <id\|all>] [--fx <name>]` | Set a solid colour. The default colour is `#000000`. |
| `macpixel check [<dir>]` | List the images that are not pixel art. See [Pixel art](#pixel-art). |
| `macpixel query` | Show each screen with its size, wallpaper and state. |
| `macpixel pause` | Stop all animations. |
| `macpixel resume` | Start the animations again. |
| `macpixel kill` | Stop the daemon. |
| `macpixel install` | Start the daemon at login. |
| `macpixel uninstall` | Remove the start at login. |

All commands except `daemon`, `check`, `install` and `uninstall` need a daemon that runs.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | The daemon reported an error (for example, a file that is not an image). For `check`: an image is not pixel art. |
| 2 | The command line is incorrect. |
| 3 | The daemon does not run. |

## Images

macpixel reads all image formats that macOS reads (PNG, JPEG, HEIC, GIF, WebP and others). GIF, APNG and WebP files with more than one frame are animated. All other files show as one frame.

The first use of an image takes a moment, because macpixel decodes it and writes a cache file. After that, a change to the same image is immediate. When a decode fails, the old wallpaper stays.

## Transitions

`img` and `clear` show the change with a transition, after the effects of [ttfx](https://github.com/omacom/ttfx). A transition runs on a grid of 540 × 270 cells and takes 1.5 to 3.5 seconds.

| Name | Effect |
|---|---|
| `burn` | A fire starts at a random cell and spreads. Some cells emit smoke. This is the default. |
| `sweep` | A shimmer of colours goes from left to right and leaves the new wallpaper. |
| `slide` | The new wallpaper comes in from the left, in bands of rows. |
| `wipe` | A diagonal band of colours goes from the top left to the bottom right. |
| `decrypt` | Green symbols flood the screen and change. A second flood shows the new wallpaper. |
| `pour` | Tiles of the new wallpaper fall and fill the screen from the bottom. |
| `smoke` | Smoke floods the screen from a random cell. |
| `vhstape` | Lines lose their colour and jump to the side. Noise covers the screen. Then each line flashes and shows the new wallpaper. |
| `rain` | Drops of the new wallpaper fall and fill the screen from the bottom. |
| `disabled` | No transition. |

```sh
macpixel img forest.gif --fx wipe      # for this change only
```

The `transition` key of the config file sets the default. `--fx` has priority. Animations play during a transition. During a transition, `img` and `clear` have no effect. There is no transition while the wallpaper is paused or not visible.

## More than one screen

`macpixel query` shows one line for each screen. The first field is the screen ID.

```
1 1470x956 /Users/me/a.gif playing
2 3840x2160 /Users/me/a.gif playing
```

Use the ID to set a wallpaper on one screen:

```sh
macpixel img ~/b.gif --screen 2
macpixel clear --color '#202020' --screen 1
```

- A command without `--screen` applies to all screens. It replaces the wallpapers that you set for one screen.
- macpixel remembers the wallpaper of each screen. It applies it again when you connect the screen and when the daemon starts.
- Screens that show the same file share one player, so a second screen does not use more memory.

## States

`query` shows one of these states for each screen:

| State | Meaning |
|---|---|
| `playing` | The animation runs. |
| `paused (<reasons>)` | The animation is stopped. The last frame stays on the screen. |
| `static` | The wallpaper is a still image or a colour. |
| `stopped` | The animation completed its loop count. |

Pause reasons:

| Reason | Cause |
|---|---|
| `occluded` | Windows or a full-screen application cover the wallpaper. |
| `displaySleep` | The display sleeps. |
| `systemSleep` | The Mac sleeps. |
| `locked` | The screen is locked. |
| `sessionInactive` | A different user is active. |
| `lowPower` | Low Power Mode is on. |
| `user` | You ran `macpixel pause`. |

Battery power alone does not pause the animation.

## Pixel art

macpixel recognizes pixel art automatically. An image is pixel art when each block of N×N pixels has one colour in all frames (for example, a 320×208 picture that is saved as 2560×1664).

- macpixel stores pixel art at its minimum pixelated size. Integer grids are reduced to single pixels. This decreases the memory and CPU use.
- Each screen shows pixel art at integer scale, so that all art pixels have the same size. The scale is the smallest one that covers the screen. The part outside the screen is cut. **It's recommended to use images close to your screen ratio**

Images that are not pixel art fill the screen and keep their aspect ratio.

`macpixel check` finds these images before you use them:

```sh
macpixel check ~/wallpapers     # a directory (default: the current directory), or one file
```

```
/Users/me/wallpapers/photo.jpg: the image is not pixel art
```

It prints one line for each `.gif`, `.png` or `.jpg` file that is not pixel art, or that macpixel cannot read. It does not look in subdirectories. The exit code is 1 when it prints a line, and 0 when all images are pixel art. It does not need the daemon.

## macOS desktop picture and lock screen

macpixel also sets the built-in macOS desktop picture to your wallpaper. This is automatic and has no option. macOS then shows the same picture where the macpixel window is not present: before the daemon starts at login, after `macpixel kill`, and on the lock screen.

- macOS shows a still picture: the first frame of an animation.
- For pixel art, macpixel gives macOS a picture with the same scale and cut as the wallpaper.
- macOS lets an application change the active Space only. Each other Space gets the picture when you go to it for the first time.
- macpixel replaces the desktop picture that you had before and does not store it. `macpixel uninstall` does not put it back.

## Files

| Path | Contents |
|---|---|
| `~/.config/macpixel/config` | Optional configuration. |
| `~/Library/Application Support/macpixel/state` | The wallpaper of each screen. The daemon reads it at start. |
| `~/Library/Caches/macpixel/` | Decoded images, and the pictures that macOS uses as desktop picture. If you delete them, set the wallpaper again. |
| `~/Library/LaunchAgents/io.macpixel.daemon.plist` | The launch agent that `install` writes. |
| `~/Library/Logs/macpixel.log` | The log of the daemon when the launch agent starts it. |

### Configuration

The `config` file has one `key = value` pair on each line. Restart the daemon after a change.

| Key | Default | Function |
|---|---|---|
| `max_cache_mb` | `512` | Maximum size of the cache directory in MB. macpixel deletes the files that were used least recently. |
| `transition` | `burn` | The transition of `img` and `clear`: `burn`, `sweep`, `slide`, `wipe`, `decrypt`, `pour`, `smoke`, `vhstape`, `rain` or `disabled`. |
| `menu_bar_color` | not set | A colour as `#RRGGBB`. macpixel shows a bar of this colour behind the macOS menu bar, so the menu bar has a static colour and does not show the wallpaper. Without this key, the menu bar shows the wallpaper. |

## Problems

| Symptom | Action |
|---|---|
| A command exits with code 3 | The daemon does not run. Run `macpixel daemon`, or `macpixel install`. |
| The wallpaper does not move | Run `macpixel query`. The pause reason shows the cause. |
| The daemon does not start at login | Read `~/Library/Logs/macpixel.log`. Make sure that the binary is at the path where it was when you ran `install`. |
| A wallpaper looks incorrect after an update | Delete `~/Library/Caches/macpixel/`, then set the wallpaper again. |

## Design

`SPEC.md` describes the design and is the source of truth for agents.
