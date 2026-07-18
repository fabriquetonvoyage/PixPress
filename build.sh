#!/bin/bash
# Build PixPress and assemble a runnable .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="PixPress.app"

echo "▶︎ Compilation ($CONFIG)…"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▶︎ Assemblage de $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/PixPress" "$APP/Contents/MacOS/PixPress"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || true

# Ad-hoc code signature so macOS launches it cleanly on this machine.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✅ $APP prêt."
echo "   Lancer :  open $APP"
