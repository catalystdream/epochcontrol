#!/bin/bash
# Build EpochControl.app (release, ad-hoc signed) into macos/build/.
# Developer ID signing and notarization come with v1.0 (PRD §12).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.2.0-dev}"
swift build -c release
APP=build/EpochControl.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp .build/release/EpochControl "$APP/Contents/MacOS/EpochControl"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>EpochControl</string>
  <key>CFBundleDisplayName</key><string>EpochControl</string>
  <key>CFBundleIdentifier</key><string>io.github.catalystdream.epochcontrol</string>
  <key>CFBundleExecutable</key><string>EpochControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP"
