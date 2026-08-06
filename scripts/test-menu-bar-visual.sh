#!/bin/zsh
# Captures the real menu-bar popover with its first device row in the hover
# state. The artifact can be visually inspected with any image viewer.
set -euo pipefail

cd "$(dirname "$0")/.."
OUTPUT_PATH="${1:-/private/tmp/deviceshots-menu-bar-visual.png}"

cleanup() {
    pkill -x DeviceShots || true
    open -n "/Applications/Device Shots.app"
}
trap cleanup EXIT

./build.sh install
pkill -x DeviceShots || true
DEVICESHOTS_VISUAL_OPEN_POPOVER=1 \
DEVICESHOTS_VISUAL_HOVER_FIRST_DEVICE=1 \
"/Applications/Device Shots.app/Contents/MacOS/DeviceShots" &
sleep 2
screencapture -x "$OUTPUT_PATH"
print "PASS: captured menu-bar hover state to $OUTPUT_PATH"
