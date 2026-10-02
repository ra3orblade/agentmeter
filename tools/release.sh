#!/bin/sh
# Build, sign, notarize and staple a release zip: dist/AgentMeter-<version>.zip, plus
# dist/appcast.xml (the Sparkle feed, attached to the same release) and dist/release-notes.md.
#
#   tools/release.sh 0.1.0
#
# Needs a "Developer ID Application" identity in the keychain (SIGN_IDENTITY overrides which),
# a CHANGELOG.md section for the version, notarization credentials, either:
#   NOTARY_PROFILE=<name>   from `xcrun notarytool store-credentials <name>` (local), or
#   APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID   (CI, same names as Swarm)
# and the Sparkle EdDSA key: in the keychain (local, account "agentmeter"), or the base64
# private key in SPARKLE_PRIVATE_KEY (CI; `generate_keys --account agentmeter -x file` exports it).
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:?usage: tools/release.sh <version>}"
VERSION="${VERSION#v}"

if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$SIGN_IDENTITY" ] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }

if [ -n "${NOTARY_PROFILE:-}" ]; then
  set -- --keychain-profile "$NOTARY_PROFILE"
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  set -- --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID"
else
  echo "set NOTARY_PROFILE, or APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID" >&2
  exit 1
fi

# A binary linked against a pre-26 SDK runs in compatibility mode on macOS 26: the dropdown
# draws its old square panel inside the new rounded window. Release only from a 26+ SDK.
SDK="$(xcrun --show-sdk-version)"
[ "${SDK%%.*}" -ge 26 ] || { echo "macOS SDK $SDK is too old: build with Xcode 26 or later" >&2; exit 1; }

mkdir -p dist
NOTES=dist/release-notes.md
awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md > "$NOTES"
test -s "$NOTES" || { echo "CHANGELOG.md has no [$VERSION] section" >&2; exit 1; }
SPARKLE_BIN="$(tools/sparkle-tools.sh)"

UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" VERSION="$VERSION" tools/bundle.sh

ZIP="dist/AgentMeter-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/AgentMeter.app "$ZIP"
xcrun notarytool submit "$ZIP" "$@" --wait
xcrun stapler staple dist/AgentMeter.app
# Re-zip so the download carries the stapled ticket and opens offline on first launch.
rm -f "$ZIP"
ditto -c -k --keepParent dist/AgentMeter.app "$ZIP"
spctl --assess --type execute --verbose dist/AgentMeter.app

# Sparkle installs an update only if this signature over the exact zip checks out.
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  ENCLOSURE="$(printf %s "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - "$ZIP")"
else
  ENCLOSURE="$("$SPARKLE_BIN/sign_update" --account agentmeter "$ZIP")"
fi
# The feed only needs the newest item: it's served from releases/latest/download/appcast.xml.
{
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Agent Meter</title>
    <item>
      <title>Agent Meter $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
XML
  cat "$NOTES"
  cat <<XML
]]></description>
      <enclosure url="https://github.com/ra3orblade/agentmeter/releases/download/v$VERSION/AgentMeter-$VERSION.zip"
        type="application/octet-stream" $ENCLOSURE/>
    </item>
  </channel>
</rss>
XML
} > dist/appcast.xml
xmllint --noout dist/appcast.xml

shasum -a 256 "$ZIP"
echo "release $ZIP"
