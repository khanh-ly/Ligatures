#!/bin/bash
# Builds "Ligatures.app" into build/. Pass --install to also copy it to /Applications.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Ligatures.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp

echo "Compiling…"
swiftc -O -o "$APP/Contents/MacOS/FontManager" macos/main.swift -framework Cocoa -framework WebKit

echo "Making icon…"
swift macos/make_icon.swift macos/logo.svg build/tmp/icon.png
ICONSET=build/tmp/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s build/tmp/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/tmp/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp macos/Info.plist "$APP/Contents/Info.plist"
cp fontmanager.py index.html "$APP/Contents/Resources/"
rm -rf build/tmp

echo "Signing (ad hoc)…"
codesign --force --deep --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  if pgrep -xq FontManager; then
    osascript -e 'tell application id "ly.khanh.fontmanager" to quit' || true
    sleep 1
  fi
  rm -rf "/Applications/Ligatures.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Ligatures.app"
fi
