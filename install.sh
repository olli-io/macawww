#!/bin/sh
# Builds macawww, copies the binary, and starts the daemon at login.
#
# usage: install.sh [--bin-dir <dir>] [--no-agent]
#   --bin-dir <dir>   where to put the binary (default: ~/.local/bin)
#   --no-agent        copy the binary only; do not start the daemon at login
#
# Run it from a checkout, or pipe it from curl. With curl, it clones the source into a temporary directory.

set -eu

REPO="https://github.com/olli-io/macawww"
BIN_DIR="$HOME/.local/bin"
AGENT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --bin-dir)
            [ $# -ge 2 ] || { echo "install.sh: --bin-dir needs a directory" >&2; exit 2; }
            BIN_DIR="$2"
            shift 2
            ;;
        --no-agent)
            AGENT=0
            shift
            ;;
        *)
            echo "usage: install.sh [--bin-dir <dir>] [--no-agent]" >&2
            exit 2
            ;;
    esac
done

fail() {
    echo "install.sh: $1" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "macawww builds only on macOS"
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || fail "macawww needs macOS 14 or later"
command -v swift >/dev/null 2>&1 || fail "swift not found. Install Xcode or run: xcode-select --install"

# Use the checkout that contains this script. If there is none (curl), clone the source.
SRC="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
TMP=""
if [ -z "$SRC" ] || ! grep -q 'name: "macawww"' "$SRC/Package.swift" 2>/dev/null; then
    command -v git >/dev/null 2>&1 || fail "git not found"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    echo "Getting the source from $REPO"
    git clone --quiet --depth 1 "$REPO" "$TMP/macawww"
    SRC="$TMP/macawww"
fi

echo "Building (release)"
(cd "$SRC" && swift build -c release)
BUILT="$SRC/.build/release/macawww"
[ -x "$BUILT" ] || fail "the build gave no binary"

DEST="$BIN_DIR/macawww"
PLIST="$HOME/Library/LaunchAgents/io.macawww.daemon.plist"

if [ "$AGENT" -eq 1 ]; then
    # Stop the old daemon before the binary changes. The wallpaper state stays on disk.
    if [ -f "$PLIST" ]; then "$BUILT" uninstall >/dev/null 2>&1 || true; fi
    "$BUILT" kill >/dev/null 2>&1 || true
fi

mkdir -p "$BIN_DIR"
# Copy to a temporary name, then rename: a binary that runs is not written in place.
cp "$BUILT" "$DEST.new"
chmod 755 "$DEST.new"
mv -f "$DEST.new" "$DEST"
echo "Installed $DEST"

if [ "$AGENT" -eq 1 ]; then
    "$DEST" install
    echo "The daemon runs now and starts at login."
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Note: $BIN_DIR is not in your PATH. Add this line to your shell profile:"
       echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

echo "Set a wallpaper with: macawww img <path>"
