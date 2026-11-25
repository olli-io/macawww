#!/bin/sh
# Downloads the released macpixel binary, copies it to a bin directory, and starts the daemon at login.
# To build from source, see "Build" in README.md.
#
# usage: install.sh [--bin-dir <dir>] [--version <vX.Y.Z>] [--no-agent] [--saver]
#   --bin-dir <dir>      where to put the binary (default: ~/.local/bin)
#   --version <vX.Y.Z>   the release to install (default: the latest release)
#   --no-agent           copy the binary only; do not start the daemon at login
#   --saver              also install the screensaver in ~/Library/Screen Savers

set -eu

REPO="olli-io/macpixel"
ASSET="macpixel-arm64-macos"
BIN_DIR="$HOME/.local/bin"
VERSION=""
AGENT=1
SAVER=0
SAVER_ASSET="macpixel.saver.zip"

while [ $# -gt 0 ]; do
    case "$1" in
        --bin-dir)
            [ $# -ge 2 ] || { echo "install.sh: --bin-dir needs a directory" >&2; exit 2; }
            BIN_DIR="$2"
            shift 2
            ;;
        --version)
            [ $# -ge 2 ] || { echo "install.sh: --version needs a release tag" >&2; exit 2; }
            VERSION="$2"
            shift 2
            ;;
        --no-agent)
            AGENT=0
            shift
            ;;
        --saver)
            SAVER=1
            shift
            ;;
        *)
            echo "usage: install.sh [--bin-dir <dir>] [--version <vX.Y.Z>] [--no-agent] [--saver]" >&2
            exit 2
            ;;
    esac
done

fail() {
    echo "install.sh: $1" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "macpixel runs only on macOS"
[ "$(uname -m)" = "arm64" ] || fail "macpixel runs only on Apple silicon"
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || fail "macpixel needs macOS 14 or later"

if [ -n "$VERSION" ]; then
    URL="https://github.com/$REPO/releases/download/$VERSION"
else
    URL="https://github.com/$REPO/releases/latest/download"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Getting $ASSET from $URL"
for f in "$ASSET" SHA256SUMS; do
    curl -fsSL -o "$TMP/$f" "$URL/$f" || fail "cannot download $URL/$f"
done
(cd "$TMP" && grep "  $ASSET\$" SHA256SUMS | shasum -a 256 -c - >/dev/null) || fail "the checksum of $ASSET is incorrect"
NEW="$TMP/$ASSET"
chmod 755 "$NEW"

DEST="$BIN_DIR/macpixel"
PLIST="$HOME/Library/LaunchAgents/io.macpixel.daemon.plist"

if [ "$AGENT" -eq 1 ]; then
    # Stop the old daemon before the binary changes. The wallpaper state stays on disk.
    if [ -f "$PLIST" ]; then "$NEW" uninstall >/dev/null 2>&1 || true; fi
    "$NEW" kill >/dev/null 2>&1 || true
fi

mkdir -p "$BIN_DIR"
# Copy to a temporary name, then rename: a binary that runs is not written in place.
cp "$NEW" "$DEST.new"
mv -f "$DEST.new" "$DEST"
echo "Installed $DEST"

if [ "$AGENT" -eq 1 ]; then
    "$DEST" install
    echo "The daemon runs now and starts at login."
fi

if [ "$SAVER" -eq 1 ]; then
    curl -fsSL -o "$TMP/$SAVER_ASSET" "$URL/$SAVER_ASSET" || fail "cannot download $URL/$SAVER_ASSET"
    (cd "$TMP" && grep "  $SAVER_ASSET\$" SHA256SUMS | shasum -a 256 -c - >/dev/null) || fail "the checksum of $SAVER_ASSET is incorrect"
    SAVER_DIR="$HOME/Library/Screen Savers"
    mkdir -p "$SAVER_DIR"
    rm -rf "$SAVER_DIR/macpixel.saver"
    ditto -x -k "$TMP/$SAVER_ASSET" "$SAVER_DIR"
    echo "Installed $SAVER_DIR/macpixel.saver"
    echo "Select macpixel in System Settings > Screen Saver."
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Note: $BIN_DIR is not in your PATH. Add this line to your shell profile:"
       echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

echo "Set a wallpaper with: macpixel img <path>"
