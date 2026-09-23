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

echo "$(ls "$OUT" | wc -l | tr -d ' ') snapshots in $OUT"
[[ "$1" == "--no-open" ]] || open "$OUT"
