#!/bin/sh
# Render the README images from synthetic logs (tools/demo-data.py) — never from your own.
set -eu
cd "$(dirname "$0")/.."
OUT=docs/images
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 tools/demo-data.py "$WORK/home"
swift build -c release --product AgentMeter
mkdir -p "$OUT"
export AGENTMETER_HOME="$WORK/home" AGENTMETER_DATA_DIR="$WORK/data"
BIN=.build/release/AgentMeter
$BIN --snapshot "$OUT/today-light.png" --period today
$BIN --snapshot "$OUT/today-dark.png" --period today --dark
$BIN --snapshot "$OUT/week-light.png" --period week
$BIN --snapshot "$OUT/week-dark.png" --period week --dark
$BIN --snapshot "$OUT/menubar-light.png" --bar
$BIN --snapshot "$OUT/menubar-dark.png" --bar --dark
ICONSET="$WORK/AppIcon.iconset"
$BIN --iconset "$ICONSET"
cp "$ICONSET/icon_128x128@2x.png" "$OUT/icon.png"
ls -1 "$OUT"
