#!/bin/bash
# Builds Pomodoro.app into ./build. Pass --install to copy it to /Applications (or ~/Applications) and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Pomodoro.app"

echo "→ Compiling…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Pomodoro"

if [ ! -f build/AppIcon.icns ]; then
    echo "→ Generating icon…"
    mkdir -p build
    swift scripts/make_icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

echo "→ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pomodoro"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    # /Applications needs admin rights; fall back to ~/Applications otherwise.
    DEST="/Applications"
    [ -w "$DEST" ] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x Pomodoro 2>/dev/null && while pgrep -x Pomodoro >/dev/null; do sleep 0.2; done || true
    rm -rf "$DEST/Pomodoro.app"
    cp -R "$APP" "$DEST/"
    echo "✓ Installed to $DEST/Pomodoro.app"
    sleep 1
    open "$DEST/Pomodoro.app"
fi
