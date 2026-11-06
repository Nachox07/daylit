#!/bin/sh
# Regenerates mac/AppIcon.icns and windows/Daylit.ico from draw.swift (macOS only).
set -e
cd "$(dirname "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O draw.swift -o "$T/draw"
mkdir "$T/AppIcon.iconset"
for p in 16 32 128 256 512; do
  "$T/draw" "$T/AppIcon.iconset/icon_${p}x${p}.png" $p mac
  "$T/draw" "$T/AppIcon.iconset/icon_${p}x${p}@2x.png" $((p * 2)) mac
done
iconutil -c icns "$T/AppIcon.iconset" -o ../../mac/AppIcon.icns
for p in 16 20 24 32 40 48 64 256; do "$T/draw" "$T/win-$p.png" $p win; done
python3 -I ico.py ../../windows/Daylit.ico "$T"/win-16.png "$T"/win-20.png "$T"/win-24.png "$T"/win-32.png \
  "$T"/win-40.png "$T"/win-48.png "$T"/win-64.png "$T"/win-256.png
"$T/draw" ../../docs/icon.png 256 mac flat   # README: no shadow, it smudges on dark pages
echo "icons written"
