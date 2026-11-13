#!/bin/sh
# Builds Daylit.app with Swift Package Manager (needs Xcode or its command-line tools).
# Output: ~/Applications/Daylit.app, or the folder given as the first argument. Tests: swift test.
# DAYLIT_VERSION sets the app version (releases pass the tag); DAYLIT_UNIVERSAL=1 builds for both
# Apple silicon and Intel (release downloads), otherwise only for this Mac's architecture.
set -e
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications}"
APP="$OUT/Daylit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Package.swift sets macOS 14 as the minimum, so the binary runs there whatever SDK builds it.
VERSION="${DAYLIT_VERSION:-0.0.0}"   # 0.0.0 = a local build; the log calls it "dev"
ARCHS=""
[ "${DAYLIT_UNIVERSAL:-0}" = 1 ] && ARCHS="--arch arm64 --arch x86_64"
swift build -c release --product Daylit $ARCHS
# A copy of this app that is running when its files are replaced loses its Local Network access
# (every Home Assistant call fails as "offline" until it restarts), so quit it now and reopen it below.
RUNNING=$(pgrep -f "$APP/Contents/MacOS/Daylit" || true)
if [ -n "$RUNNING" ]; then kill $RUNNING; while pgrep -f "$APP/Contents/MacOS/Daylit" >/dev/null; do sleep 0.2; done; fi
cp "$(swift build -c release --show-bin-path $ARCHS)/Daylit" "$APP/Contents/MacOS/Daylit"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # made by packaging/icon/make.sh
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.daylit.mac</string>
  <key>CFBundleName</key><string>Daylit</string>
  <key>CFBundleExecutable</key><string>Daylit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSAppleEventsUsageDescription</key><string>Daylit switches light and dark mode through System Events, only if you turn that on.</string>
  <key>NSLocationUsageDescription</key><string>Only when you click Locate Me: Daylit saves your city-level location to follow the sun.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Only when you click Locate Me: Daylit saves your city-level location to follow the sun.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Daylit reads the sun, blind and lights from Home Assistant.</string>
</dict></plist>
PL
# Sign with a stable identity when one exists, so macOS keeps the Accessibility and Local Network
# permissions across rebuilds and updates (an ad-hoc signature changes every build and macOS forgets
# them). DAYLIT_SIGN_IDENTITY (a certificate hash or name; releases set it from the MAC_CERT_P12
# secret) wins, then an Apple Development identity, else ad-hoc.
ID="${DAYLIT_SIGN_IDENTITY:-}"
[ -n "$ID" ] || ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')
codesign --force -s "${ID:--}" "$APP"
echo "built $APP"
if [ -n "$RUNNING" ]; then open "$APP"; echo "restarted the running Daylit"; fi
