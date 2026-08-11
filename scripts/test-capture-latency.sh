#!/bin/zsh
# Measures Device Shots trigger→clipboard and trigger→paste latency through the
# real capture path (same work as a global hotkey after the device list is warm),
# then checks results against scripts/latency-budgets.json.
#
# Usage:
#   ./scripts/test-capture-latency.sh
#   ./scripts/test-capture-latency.sh --iterations 2 --index 0 --no-paste
#   ./scripts/test-capture-latency.sh --no-budget   # report only, do not fail on budgets
#
# Requires a connected / booted device at the chosen menu index. Paste timings
# need Accessibility access for Device Shots (clipboard timings do not).
set -euo pipefail

cd "$(dirname "$0")/.."

ITERATIONS=2
WARMUP=1
INDEX=0
MEASURE_PASTE=1
CHECK_BUDGET=1
OUT=""
BUDGETS="scripts/latency-budgets.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iterations|-n)
            ITERATIONS="${2:?}"
            shift 2
            ;;
        --warmup)
            WARMUP="${2:?}"
            shift 2
            ;;
        --index)
            INDEX="${2:?}"
            shift 2
            ;;
        --out)
            OUT="${2:?}"
            shift 2
            ;;
        --budgets)
            BUDGETS="${2:?}"
            shift 2
            ;;
        --no-paste)
            MEASURE_PASTE=0
            shift
            ;;
        --no-budget)
            CHECK_BUDGET=0
            shift
            ;;
        --help|-h)
            sed -n '2,14p' "$0"
            exit 0
            ;;
        *)
            print -u2 "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$OUT" ]]; then
    OUT="/private/tmp/deviceshots-latency-$$.json"
fi

./build.sh

APP="./Device Shots.app"
BIN="$APP/Contents/MacOS/DeviceShots"
if [[ ! -x "$BIN" ]]; then
    print -u2 "FAIL: missing $BIN"
    exit 1
fi

# Avoid fighting an already-running menu-bar instance.
pkill -x DeviceShots 2>/dev/null || true
sleep 0.3

print "Running latency bench → $OUT"
print "  iterations=$ITERATIONS warmup=$WARMUP index=$INDEX paste=$MEASURE_PASTE budget=$CHECK_BUDGET"

set +e
DEVICESHOTS_BENCH=1 \
DEVICESHOTS_BENCH_ITERATIONS="$ITERATIONS" \
DEVICESHOTS_BENCH_WARMUP="$WARMUP" \
DEVICESHOTS_BENCH_INDEX="$INDEX" \
DEVICESHOTS_BENCH_PASTE="$MEASURE_PASTE" \
DEVICESHOTS_BENCH_OUT="$OUT" \
"$BIN"
STATUS=$?
set -e

if [[ ! -f "$OUT" ]]; then
    print -u2 "FAIL: bench did not write $OUT (exit $STATUS)"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    print "Raw report: $OUT"
    cat "$OUT"
    exit 0
fi

device=$(jq -r '"\(.deviceName) (\(.deviceKind))"' "$OUT")
kind=$(jq -r '.deviceKind' "$OUT")
error=$(jq -r '.samples[0].error // empty' "$OUT")
ok_count=$(jq '[.samples[] | select(.ok)] | length' "$OUT")
total=$(jq '.samples | length' "$OUT")

print ""
print "Device: $device"
print "Samples: $ok_count/$total ok"

if [[ "$ok_count" -eq 0 ]]; then
    print -u2 "FAIL: ${error:-no successful captures}"
    exit 1
fi

print_stats() {
    local label="$1"
    local key="$2"
    if jq -e --arg key "$key" '.[$key] != null' "$OUT" >/dev/null; then
        local median mean min max count
        median=$(jq --arg key "$key" '.[$key].median' "$OUT")
        mean=$(jq --arg key "$key" '.[$key].mean' "$OUT")
        min=$(jq --arg key "$key" '.[$key].min' "$OUT")
        max=$(jq --arg key "$key" '.[$key].max' "$OUT")
        count=$(jq --arg key "$key" '.[$key].count' "$OUT")
        printf "%s: median %.1f ms  mean %.1f  min %.1f  max %.1f  (n=%s)\n" \
            "$label" "$median" "$mean" "$min" "$max" "$count"
    else
        print "$label: (no samples)"
    fi
}

print_stats "trigger→clipboard" "clipboardMs"
print_stats "trigger→paste" "pasteMs"
print_stats "device tool only" "deviceToolMs"
print_stats "app delivery overhead" "deliveryOverheadMs"
print_stats "paste delta" "pasteDeltaMs"

paste_denied=$(jq '[.samples[] | select(.pasted == false)] | length' "$OUT")
if [[ "$MEASURE_PASTE" -eq 1 && "$paste_denied" -gt 0 ]]; then
    print "Note: $paste_denied run(s) copied but could not paste (grant Accessibility to Device Shots)."
fi

if [[ "$CHECK_BUDGET" -eq 0 ]]; then
    print ""
    print "PASS: full report at $OUT (budgets skipped)"
    exit 0
fi

if [[ ! -f "$BUDGETS" ]]; then
    print -u2 "FAIL: missing budgets file $BUDGETS"
    exit 1
fi

case "$kind" in
    android|ios|simulator) ;;
    *)
        print -u2 "FAIL: unknown deviceKind '$kind' for budget lookup"
        exit 1
        ;;
esac

FAILED=0
check_budget() {
    local label="$1"
    local report_key="$2"
    local budget_expr="$3"
    local stat="$4" # median|max

    if ! jq -e --arg key "$report_key" '.[$key] != null' "$OUT" >/dev/null; then
        return 0
    fi

    local actual limit
    actual=$(jq --arg key "$report_key" --arg stat "$stat" '.[$key][$stat]' "$OUT")
    limit=$(jq -r "$budget_expr" "$BUDGETS")
    if [[ "$limit" == "null" || -z "$limit" ]]; then
        print -u2 "FAIL: budget missing for $budget_expr"
        FAILED=1
        return
    fi

    awk -v a="$actual" -v l="$limit" -v label="$label" -v stat="$stat" 'BEGIN {
        if (a > l + 0) {
            printf "BUDGET FAIL: %s %s %.1f ms exceeds %.0f ms\n", label, stat, a, l > "/dev/stderr"
            exit 1
        }
        printf "BUDGET OK: %s %s %.1f ms ≤ %.0f ms\n", label, stat, a, l
        exit 0
    }' || FAILED=1
}

print ""
print "Budgets ($BUDGETS):"

check_budget "app delivery overhead" "deliveryOverheadMs" ".app.deliveryOverheadMedianMs" "median"
check_budget "app delivery overhead" "deliveryOverheadMs" ".app.deliveryOverheadMaxMs" "max"
if [[ "$MEASURE_PASTE" -eq 1 && "$paste_denied" -eq 0 ]]; then
    check_budget "paste delta" "pasteDeltaMs" ".app.pasteDeltaMedianMs" "median"
    check_budget "paste delta" "pasteDeltaMs" ".app.pasteDeltaMaxMs" "max"
fi
check_budget "trigger→clipboard" "clipboardMs" ".$kind.clipboardMedianMs" "median"
check_budget "trigger→clipboard" "clipboardMs" ".$kind.clipboardMaxMs" "max"
if [[ "$MEASURE_PASTE" -eq 1 && "$paste_denied" -eq 0 ]]; then
    check_budget "trigger→paste" "pasteMs" ".$kind.pasteMedianMs" "median"
    check_budget "trigger→paste" "pasteMs" ".$kind.pasteMaxMs" "max"
fi

print ""
if [[ "$FAILED" -ne 0 ]]; then
    print -u2 "FAIL: latency budgets exceeded — report at $OUT"
    exit 1
fi
print "PASS: within budgets — report at $OUT"
