#!/bin/sh
# Build a release AgentMeter.app into dist/ (ad-hoc signed; no Xcode needed).
set -eu
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
swift build -c release --product AgentMeter
APP=dist/AgentMeter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AgentMeter "$APP/Contents/MacOS/AgentMeter"
# The icon is drawn by the app's own Logo code, so it never drifts from the menu bar glyph.
ICONSET="$(mktemp -d)/AppIcon.iconset"
.build/release/AgentMeter --iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AgentMeter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>dev.agentmeter.AgentMeter</string>
  <key>CFBundleName</key><string>Agent Meter</string>
  <key>CFBundleDisplayName</key><string>Agent Meter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Apache-2.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP"
