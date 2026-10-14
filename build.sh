#!/bin/sh
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Peroxide.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Peroxide" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.jesodium.peroxide</string>
  <key>CFBundleName</key><string>Peroxide</string>
  <key>CFBundleExecutable</key><string>Peroxide</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Peroxide syncs your light to the music your Mac is playing. Audio never leaves your Mac.</string>
  <key>NSMicrophoneUsageDescription</key><string>Peroxide listens for claps to toggle your light. Audio never leaves your Mac.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Peroxide talks to your Tuya bulb directly over your Wi-Fi.</string>
</dict></plist>
PLIST
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force -s "${ID:--}" "$APP"
pkill -x Peroxide || true
rm -rf /Applications/Peroxide.app && cp -R "$APP" /Applications/
open /Applications/Peroxide.app
echo "installed /Applications/Peroxide.app"
