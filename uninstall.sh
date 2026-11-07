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

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
MACOS_DIR="$APP_PATH/Contents/MacOS"

if [ -f "$MACOS_DIR/project-reclaimer-bin" ]; then
    echo "==> Restoring original binary..."
    mv "$MACOS_DIR/project-reclaimer-bin" "$MACOS_DIR/project-reclaimer"
fi

rm -f "$FRAMEWORKS_DIR/librumble_bridge_native.dylib"

echo "==> Re-signing bundle..."
codesign --force --sign - "$APP_PATH"

echo "==> Successfully removed rumble bridge from $APP_PATH."
