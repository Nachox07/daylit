#!/bin/sh
# Builds Daylit.app (needs the Xcode command-line tools). Output: ~/Applications/Daylit.app,
# or the folder given as the first argument.
set -e
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications}"
APP="$OUT/Daylit.app"
mkdir -p "$APP/Contents/MacOS"
# Target macOS 14 explicitly; otherwise the binary requires the SDK's (newer) macOS version.
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" Daylit.swift -o "$APP/Contents/MacOS/Daylit"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.daylit.mac</string>
  <key>CFBundleName</key><string>Daylit</string>
  <key>CFBundleExecutable</key><string>Daylit</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSAppleEventsUsageDescription</key><string>Daylit switches light and dark mode through System Events, only if you turn that on.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Daylit reads the sun, blind and lights from Home Assistant.</string>
</dict></plist>
PL
# Sign with a stable identity when one exists, so macOS keeps the Accessibility permission across
# rebuilds (an ad-hoc signature changes every build and macOS forgets the permission).
ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')
codesign --force -s "${ID:--}" "$APP"
echo "built $APP"
