#!/bin/zsh
# Builds CadMac.app from the Swift package (no Xcode required).
set -e
cd "$(dirname "$0")"
CONFIG=${1:-release}
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)
APP=build/CadMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CadMac" "$APP/Contents/MacOS/CadMac"
cp "$BIN/cadmac-mcp" "$APP/Contents/MacOS/cadmac-mcp"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp -R Support/Help "$APP/Contents/Resources/Help"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
