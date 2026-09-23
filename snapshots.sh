#!/bin/zsh
# Renders every Settings and setup-guide state to Snapshots/*.png (light and
# dark) without building or installing the app, then opens the folder.
#   ./snapshots.sh            render and open in Finder
#   ./snapshots.sh --no-open  render only
set -e
cd "$(dirname "$0")"

OUT="$PWD/Snapshots"
rm -rf "$OUT"
mkdir -p "$OUT"

LOG=$(mktemp)
if ! SNAPSHOT_DIR="$OUT" swift test --filter SnapshotTests >"$LOG" 2>&1; then
    grep -E "error|failed" "$LOG" | head -20
    echo "Snapshot run failed (full log: $LOG)"
    exit 1
fi
rm -f "$LOG"

# Real windows: launch the debug app with each setup guide open, fail if it
# dies (offscreen renders can't catch window-layout crashes), and screenshot
# the actual window.
swift build >/dev/null
for guide in ios android; do
    DEVICESHOTS_SHOW_SETUP=$guide .build/debug/DeviceShots >/dev/null 2>&1 &
    PID=$!
    sleep 4
    if ! kill -0 $PID 2>/dev/null; then
        wait $PID || true
        echo "App crashed opening the $guide setup window"
        exit 1
    fi
    if WID=$(swift scripts/window-id.swift $PID "Set up"); then
        screencapture -o -l "$WID" "$OUT/real-window-setup-$guide.png"
    else
        echo "No $guide setup window found"
        kill $PID
        exit 1
    fi
    kill $PID
done

echo "$(ls "$OUT" | wc -l | tr -d ' ') snapshots in $OUT"
[[ "$1" == "--no-open" ]] || open "$OUT"
