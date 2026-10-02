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
# Sparkle checks updates against the appcast on the latest GitHub release, and installs only
# archives signed with the private half of this key (see tools/release.sh).
FEED_URL=https://github.com/ra3orblade/agentmeter/releases/latest/download/appcast.xml
SPARKLE_PUBLIC_KEY=g4+e2//EqayMva/OOS32XsxAnPBrXTal2bbaYG97X/k=

if [ "${UNIVERSAL:-0}" = 1 ]; then
  # One build per arch, then lipo: works with the Command Line Tools, unlike `--arch a --arch b`.
  for arch in arm64 x86_64; do
    swift build -c release --product AgentMeter --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch"
  done
  BIN="$(mktemp -d)/AgentMeter"
  lipo -create -output "$BIN" .build/arm64/release/AgentMeter .build/x86_64/release/AgentMeter
  ICON_BIN=".build/$(uname -m)/release/AgentMeter"
  SPARKLE=.build/arm64/release/Sparkle.framework
else
  swift build -c release --product AgentMeter
  BIN=.build/release/AgentMeter
  ICON_BIN="$BIN"
  SPARKLE=.build/release/Sparkle.framework
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentMeter"
# SwiftPM links Sparkle via @rpath and only adds @loader_path, which is right for `swift run`.
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/AgentMeter" 2>/dev/null
# The XPC services are only for sandboxed apps; this one isn't.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
  "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
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
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
</dict>
</plist>
PLIST

if [ -n "${SIGN_IDENTITY:-}" ]; then
  # Hardened runtime + secure timestamp: both required for notarization. No entitlements: the
  # app isn't sandboxed and needs none of the runtime exceptions.
  set -- --force --options runtime --timestamp --sign "$SIGN_IDENTITY"
else
  set -- --force --sign -
fi
# Inside out, never --deep: Sparkle's helpers, then the framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign "$@" "$FW/Versions/B/Autoupdate"
codesign "$@" "$FW/Versions/B/Updater.app"
codesign "$@" "$FW"
codesign "$@" "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/AgentMeter"))"
