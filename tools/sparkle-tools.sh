#!/bin/sh
# Print the path of Sparkle's command line tools (sign_update, generate_keys, …), downloading
# them on first use. They ship in the Sparkle release tarball, not in the Swift package, so this
# fetches the tarball of the version Package.resolved pins.
#
#   "$(tools/sparkle-tools.sh)/generate_keys"     # one time: make the EdDSA update signing key
set -eu
cd "$(dirname "$0")/.."
V="$(sed -n '/"identity" : "sparkle"/,/}/s/.*"version" : "\(.*\)".*/\1/p' Package.resolved)"
[ -n "$V" ] || { echo "no Sparkle version in Package.resolved" >&2; exit 1; }
DIR=".build/sparkle-tools/$V"
if [ ! -x "$DIR/bin/sign_update" ]; then
  mkdir -p "$DIR"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$V/Sparkle-$V.tar.xz" | tar -xJ -C "$DIR" ./bin
fi
echo "$PWD/$DIR/bin"
