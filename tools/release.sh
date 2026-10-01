#!/bin/sh
# Build, sign, notarize and staple a release zip: dist/AgentMeter-<version>.zip
#
#   tools/release.sh 0.1.0
#
# Needs a "Developer ID Application" identity in the keychain (SIGN_IDENTITY overrides which)
# and notarization credentials, either:
#   NOTARY_PROFILE=<name>   from `xcrun notarytool store-credentials <name>` (local), or
#   APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID   (CI, same names as Swarm)
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
shasum -a 256 "$ZIP"
echo "release $ZIP"
