#!/bin/bash
set -euo pipefail

APP_PATH="${1:-/Applications/Project Reclaimer.app}"
if [ ! -d "$APP_PATH" ]; then
    if [ -d "$HOME/Applications/Project Reclaimer.app" ]; then
        APP_PATH="$HOME/Applications/Project Reclaimer.app"
    else
        echo "Error: Project Reclaimer.app not found in /Applications or ~/Applications."
        exit 1
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
MACOS_DIR="$APP_PATH/Contents/MacOS"

echo "==> Building native 8BitDo rumble bridge..."
clang -arch arm64 -dynamiclib -O2 -fobjc-arc \
    -framework Foundation -framework GameController -framework CoreHaptics -framework IOKit \
    "$SCRIPT_DIR/bridge/native_rumble_bridge.m" \
    -o "$SCRIPT_DIR/bridge/librumble_bridge_native.dylib"

echo "==> Installing bridge into $APP_PATH..."
mkdir -p "$FRAMEWORKS_DIR"
cp "$SCRIPT_DIR/bridge/librumble_bridge_native.dylib" "$FRAMEWORKS_DIR/librumble_bridge_native.dylib"

if [ ! -f "$MACOS_DIR/project-reclaimer-bin" ]; then
    echo "==> Backing up original binary..."
    cp "$MACOS_DIR/project-reclaimer" "$MACOS_DIR/project-reclaimer-bin"
fi

echo "==> Compiling Mach-O launch wrapper..."
clang -arch arm64 -O2 "$SCRIPT_DIR/bridge/wrapper.c" -o "$MACOS_DIR/project-reclaimer"

echo "==> Signing bundle..."
codesign --force --sign - "$FRAMEWORKS_DIR/librumble_bridge_native.dylib"
codesign --force --sign - "$APP_PATH"

echo "==> Successfully installed 8BitDo rumble bridge into $APP_PATH!"
echo "    You can launch the game normally from Finder, Dock, or Terminal."
