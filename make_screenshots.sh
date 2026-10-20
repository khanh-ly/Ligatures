#!/bin/bash
# Regenerates the README screenshots (light and dark) from the current index.html.
# Usage: ./make_screenshots.sh [output folder, default: docs]
set -euo pipefail

cd "$(dirname "$0")"
OUT="${1:-docs}"
PORT="${SCREENSHOT_PORT:-8799}"
WORK="$(mktemp -d)"
SERVER=""
trap '[ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; rm -rf "$WORK"' EXIT

# A server with empty, temporary data, so the screenshots never show your own installed fonts or favorites.
mkdir -p "$WORK/home"
HOME="$WORK/home" FONTMANAGER_PORT="$PORT" python3 fontmanager.py --no-browser > "$WORK/server.log" 2>&1 &
SERVER=$!
disown "$SERVER"  # no "Terminated" message when it is stopped at the end

echo "Compiling the renderer…"
swiftc -O -swift-version 5 -o "$WORK/make_screenshot" macos/make_screenshot.swift -framework Cocoa -framework WebKit

echo "Waiting for the server (it downloads the font catalogs first)…"
for _ in $(seq 1 120); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  kill -0 "$SERVER" 2>/dev/null || { echo "The server stopped:"; cat "$WORK/server.log"; exit 1; }
  sleep 0.5
done

mkdir -p "$OUT"
for mode in light dark; do
  echo "Rendering ${mode}…"
  "$WORK/make_screenshot" "http://127.0.0.1:$PORT/" "$OUT/screenshot-$mode.png" "$mode"
done
echo "Saved $OUT/screenshot-light.png and $OUT/screenshot-dark.png"
