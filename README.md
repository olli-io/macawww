# macawww

macawww is a wallpaper manager for macOS optimized for pixelart.

## Requirements

- macOS 14 or later.
- Swift 5.9 or later (Xcode or the Command Line Tools) to build.

## Install

### With curl

```sh
curl -fsSL https://raw.githubusercontent.com/olli-io/macawww/main/install.sh | sh
```

The script does these steps:

1. It gets the source into a temporary directory and builds it.
2. It copies the binary to `~/.local/bin/macawww`.
3. It runs `macawww install`, which starts the daemon now and at each login.

Read the script before you run it: [install.sh](install.sh).

### From a checkout

```sh
git clone https://github.com/olli-io/macawww
cd macawww
./install.sh
```

### Options

| Option | Function |
|---|---|
| `--bin-dir <dir>` | Put the binary in `<dir>`. The default is `~/.local/bin`. |
| `--no-agent` | Copy the binary only. Do not start the daemon at login. |

To update, run the script again. It stops the old daemon, replaces the binary and starts the new daemon. Your wallpapers stay.

To remove macawww, run `macawww uninstall`, then delete the binary.

### Manual build

```sh
swift build -c release
```

The binary is `.build/release/macawww`. Copy it to a directory in your `PATH`:

```sh
cp .build/release/macawww ~/.local/bin/
```

To run the tests:<D-s>

```sh
swift test
```

## Quick start

1. Start the daemon at login. This command also starts it now. The install script already does this step.

   ```sh
   macawww install
   ```

2. Set a wallpaper.

   ```sh
   macawww img ~/Pictures/wallpaper.gif
   ```

3. Look at the state.

   ```sh
   macawww query
   ```

   ```
   1 1470x956 /Users/me/Pictures/wallpaper.gif playing
   ```

`install` writes the absolute path of the binary into the launch agent. Copy the binary to its final location before you run `install`. If you move the binary later, run `macawww uninstall`, then `macawww install` again.

To try macawww without the launch agent, run `macawww daemon` in a terminal. It stays in the foreground.

## Commands

| Command | Function |
|---|---|
| `macawww daemon` | Start the daemon in the foreground. |
| `macawww img <path> [--screen <id\|all>]` | Set an image as wallpaper. The default screen is `all`. |
| `macawww clear [--color <hex>] [--screen <id\|all>]` | Set a solid colour. The default colour is `#000000`. |
| `macawww query` | Show each screen with its size, wallpaper and state. |
| `macawww pause` | Stop all animations. |
| `macawww resume` | Start the animations again. |
| `macawww kill` | Stop the daemon. |
| `macawww install` | Start the daemon at login. |
| `macawww uninstall` | Remove the start at login. |

All commands except `daemon`, `install` and `uninstall` need a daemon that runs.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | The daemon reported an error (for example, a file that is not an image). |
| 2 | The command line is incorrect. |
| 3 | The daemon does not run. |

## Images

macawww reads all image formats that macOS reads (PNG, JPEG, HEIC, GIF, WebP and others). GIF, APNG and WebP files with more than one frame are animated. All other files show as one frame.

The first use of an image takes a moment, because macawww decodes it and writes a cache file. After that, a change to the same image is immediate. When a decode fails, the old wallpaper stays.

## More than one screen

`macawww query` shows one line for each screen. The first field is the screen ID.

```
1 1470x956 /Users/me/a.gif playing
2 3840x2160 /Users/me/a.gif playing
```

Use the ID to set a wallpaper on one screen:

```sh<D-s>
macawww img ~/b.gif --screen 2
macawww clear --color '#202020' --screen 1
```

- A command without `--screen` applies to all screens. It replaces the wallpapers that you set for one screen.
- macawww remembers the wallpaper of each screen. It applies it again when you connect the screen and when the daemon starts.
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
| `user` | You ran `macawww pause`. |

Battery power alone does not pause the animation.

## Pixel art

macawww recognizes pixel art automatically. An image is pixel art when each block of N×N pixels has one colour in all frames (for example, a 320×208 picture that is saved as 2560×1664).

- macawww stores pixel art at its minimum pixelated size. Integer grids are reduced to single pixels. This decreases the memory and CPU use.
- Each screen shows pixel art at integer scale, so that all art pixels have the same size. The scale is the smallest one that covers the screen. The part outside the screen is cut. **It's recommended to use images close to your screen ratio**

Images that are not pixel art fill the screen and keep their aspect ratio.

## macOS desktop picture and lock screen

macawww also sets the built-in macOS desktop picture to your wallpaper. This is automatic and has no option. macOS then shows the same picture where the macawww window is not present: before the daemon starts at login, after `macawww kill`, and on the lock screen.

- macOS shows a still picture: the first frame of an animation.
- For pixel art, macawww gives macOS a picture with the same scale and cut as the wallpaper.
- macOS lets an application change the active Space only. Each other Space gets the picture when you go to it for the first time.
- macawww replaces the desktop picture that you had before and does not store it. `macawww uninstall` does not put it back.

## Files

| Path | Contents |
|---|---|
| `~/Library/Application Support/macawww/state` | The wallpaper of each screen. The daemon reads it at start. |
| `~/Library/Application Support/macawww/config` | Optional configuration. |
| `~/Library/Caches/macawww/` | Decoded images, and the pictures that macOS uses as desktop picture. If you delete them, set the wallpaper again. |
| `~/Library/LaunchAgents/io.macawww.daemon.plist` | The launch agent that `install` writes. |
| `~/Library/Logs/macawww.log` | The log of the daemon when the launch agent starts it. |

### Configuration

The `config` file has one `key = value` pair on each line. Restart the daemon after a change.

| Key | Default | Function |
|---|---|---|
| `max_cache_mb` | `512` | Maximum size of the cache directory in MB. macawww deletes the files that were used least recently. |

## Problems

| Symptom | Action |
|---|---|
| A command exits with code 3 | The daemon does not run. Run `macawww daemon`, or `macawww install`. |
| The wallpaper does not move | Run `macawww query`. The pause reason shows the cause. |
| The daemon does not start at login | Read `~/Library/Logs/macawww.log`. Make sure that the binary is at the path where it was when you ran `install`. |
| A wallpaper looks incorrect after an update | Delete `~/Library/Caches/macawww/`, then set the wallpaper again. |

## Design

`SPEC.md` describes the design and is the source of truth for agents.
