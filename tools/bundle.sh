#!/bin/sh
# Build AgentMeter.app into dist/. No Xcode needed.
#
#   tools/bundle.sh                         # this Mac's arch, ad-hoc signed (local use)
#   UNIVERSAL=1 SIGN_IDENTITY="Developer ID Application: …" VERSION=0.1.0 tools/bundle.sh
#                                           # arm64 + x86_64, hardened runtime, for release
set -eu
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP=dist/AgentMeter.app

if [ "${UNIVERSAL:-0}" = 1 ]; then
  # One build per arch, then lipo: works with the Command Line Tools, unlike `--arch a --arch b`.
  for arch in arm64 x86_64; do
    swift build -c release --product AgentMeter --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch"
  done
  BIN="$(mktemp -d)/AgentMeter"
  lipo -create -output "$BIN" .build/arm64/release/AgentMeter .build/x86_64/release/AgentMeter
  ICON_BIN=".build/$(uname -m)/release/AgentMeter"
else
  swift build -c release --product AgentMeter
  BIN=.build/release/AgentMeter
  ICON_BIN="$BIN"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentMeter"
# The icon is drawn by the app's own Logo code, so it never drifts from the menu bar glyph.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$ICON_BIN" --iconset "$ICONSET"
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
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Apache-2.0</string>
</dict>
</plist>
PLIST

if [ -n "${SIGN_IDENTITY:-}" ]; then
  # Hardened runtime + secure timestamp: both required for notarization. No entitlements: the
  # app isn't sandboxed and needs none of the runtime exceptions.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/AgentMeter"))"
