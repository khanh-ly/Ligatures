#!/bin/bash
# Builds "Ligatures.app" into build/. Pass --install to also copy it to /Applications.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Ligatures.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp

# One binary for Apple silicon and Intel Macs, running on macOS 12 and later.
MIN_MACOS=12.0
for ARCH in arm64 x86_64; do
  echo "Compiling for ${ARCH}…"
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos$MIN_MACOS" -o "build/tmp/Ligatures-$ARCH" \
    macos/main.swift macos/FontServer.swift -framework Cocoa -framework WebKit -framework Network
done
lipo -create -output "$APP/Contents/MacOS/Ligatures" build/tmp/Ligatures-arm64 build/tmp/Ligatures-x86_64

echo "Making icon…"
swift macos/make_icon.swift build/tmp/icon.png
ICONSET=build/tmp/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s build/tmp/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/tmp/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp macos/Info.plist "$APP/Contents/Info.plist"
cp index.html "$APP/Contents/Resources/"
rm -rf build/tmp

echo "Signing (ad hoc)…"
codesign --force --deep --sign - "$APP"

# A zip that keeps the bundle intact, for copying the app to another Mac.
ditto -c -k --sequesterRsrc --keepParent "$APP" "build/Ligatures.zip"

echo "Built $APP"
echo "Built build/Ligatures.zip (for other Macs)"
if [[ "${1:-}" == "--install" ]]; then
  # Quit a running copy first (found by bundle ID, so this also catches older builds)
  osascript -e 'if application id "ly.khanh.fontmanager" is running then tell application id "ly.khanh.fontmanager" to quit' || true
  sleep 1
  rm -rf "/Applications/Ligatures.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Ligatures.app"
fi
