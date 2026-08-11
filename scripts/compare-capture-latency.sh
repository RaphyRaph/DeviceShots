#!/bin/zsh
# A/B each latency optimization against a legacy baseline and rank bang-for-buck.
#
# Usage:
#   ./scripts/compare-capture-latency.sh
#   ./scripts/compare-capture-latency.sh --iterations 2 --android-index 0 --ios-index 1
set -euo pipefail

cd "$(dirname "$0")/.."

ITERATIONS=2
WARMUP=1
ANDROID_INDEX=0
IOS_INDEX=1
OUT_DIR="/private/tmp/deviceshots-latency-compare-$$"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iterations|-n) ITERATIONS="${2:?}"; shift 2 ;;
        --warmup) WARMUP="${2:?}"; shift 2 ;;
        --android-index) ANDROID_INDEX="${2:?}"; shift 2 ;;
        --ios-index) IOS_INDEX="${2:?}"; shift 2 ;;
        --out-dir) OUT_DIR="${2:?}"; shift 2 ;;
        --help|-h)
            sed -n '2,8p' "$0"
            exit 0
            ;;
        *) print -u2 "Unknown option: $1"; exit 1 ;;
    esac
done

mkdir -p "$OUT_DIR"
./build.sh >/dev/null
BIN="./Device Shots.app/Contents/MacOS/DeviceShots"
[[ -x "$BIN" ]] || { print -u2 "FAIL: missing $BIN"; exit 1; }

pkill -x DeviceShots 2>/dev/null || true
sleep 0.3

run_variant() {
    local name="$1"
    local index="$2"
    shift 2
    local out="$OUT_DIR/${name}.json"
    local log="$OUT_DIR/${name}.log"
    print "—— $name (index=$index) ——"
    pkill -x DeviceShots 2>/dev/null || true
    sleep 0.2
    # Avoid zsh's read-only $status by not capturing $? into a named var mid-function.
    if ! env "$@" \
        DEVICESHOTS_BENCH=1 \
        DEVICESHOTS_BENCH_ITERATIONS="$ITERATIONS" \
        DEVICESHOTS_BENCH_WARMUP="$WARMUP" \
        DEVICESHOTS_BENCH_INDEX="$index" \
        DEVICESHOTS_BENCH_PASTE=1 \
        DEVICESHOTS_BENCH_OUT="$out" \
        "$BIN" >"$log" 2>&1
    then
        if [[ ! -f "$out" ]]; then
            print -u2 "FAIL: $name did not write report"
            tail -n 20 "$log" >&2 || true
            return 1
        fi
    fi
    if [[ ! -f "$out" ]]; then
        print -u2 "FAIL: $name missing report"
        tail -n 20 "$log" >&2 || true
        return 1
    fi
    local ok median overhead discovery
    ok=$(jq '[.samples[] | select(.ok)] | length' "$out")
    median=$(jq -r '.clipboardMs.median // "null"' "$out")
    overhead=$(jq -r '.deliveryOverheadMs.median // "null"' "$out")
    discovery=$(jq -r '.discoveryMs.median // "null"' "$out")
    printf "  ok=%s clipboard_median=%s delivery_overhead_median=%s discovery_median=%s\n" \
        "$ok" "$median" "$overhead" "$discovery"
}

# Variants:
# - baseline_legacy: pre-optimization hotkey path (refresh every time + sync TIFF)
# - skip_refresh: cached devices, sync TIFF (isolates opt 1)
# - defer_tiff: no discovery, deferred TIFF (opt 2 alone vs sync)
# - skip_tiff: no discovery, no TIFF (opt 3)
# - parallel_getprop: discovery on + parallel getprop
# - direct_xcode: no discovery, direct binaries (iOS mainly)
# - fast_discovery: discovery on + shorter timeout
# - all_on: production-ish combined (skip refresh + defer TIFF + parallel getprop + direct xcode)

print "Building comparison in $OUT_DIR"
print "iterations=$ITERATIONS warmup=$WARMUP android=$ANDROID_INDEX ios=$IOS_INDEX"
print ""

# --- Android ---
print "### Android"
run_variant "android_baseline_legacy" "$ANDROID_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=1 \
    DEVICESHOTS_OPT_HOTKEY_REFRESH=1 \
    DEVICESHOTS_OPT_TIFF=sync \
    DEVICESHOTS_OPT_PARALLEL_GETPROP=0 \
    DEVICESHOTS_OPT_DIRECT_XCODE=0 \
    DEVICESHOTS_OPT_DISCOVERY_TIMEOUT=10

run_variant "android_skip_refresh" "$ANDROID_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=0 \
    DEVICESHOTS_OPT_HOTKEY_REFRESH=0 \
    DEVICESHOTS_OPT_TIFF=sync \
    DEVICESHOTS_OPT_PARALLEL_GETPROP=0 \
    DEVICESHOTS_OPT_DIRECT_XCODE=0

run_variant "android_defer_tiff" "$ANDROID_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=0 \
    DEVICESHOTS_OPT_TIFF=deferred \
    DEVICESHOTS_OPT_PARALLEL_GETPROP=0 \
    DEVICESHOTS_OPT_DIRECT_XCODE=0

run_variant "android_skip_tiff" "$ANDROID_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=0 \
    DEVICESHOTS_OPT_TIFF=skip \
    DEVICESHOTS_OPT_PARALLEL_GETPROP=0 \
    DEVICESHOTS_OPT_DIRECT_XCODE=0

run_variant "android_parallel_getprop" "$ANDROID_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=1 \
    DEVICESHOTS_OPT_HOTKEY_REFRESH=1 \
    DEVICESHOTS_OPT_TIFF=sync \
    DEVICESHOTS_OPT_PARALLEL_GETPROP=1 \
    DEVICESHOTS_OPT_DIRECT_XCODE=0 \
    DEVICESHOTS_OPT_DISCOVERY_TIMEOUT=10

run_variant "android_all_on" "$ANDROID_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=0 \
    DEVICESHOTS_OPT_HOTKEY_REFRESH=0 \
    DEVICESHOTS_OPT_TIFF=deferred \
    DEVICESHOTS_OPT_PARALLEL_GETPROP=1 \
    DEVICESHOTS_OPT_DIRECT_XCODE=1 \
    DEVICESHOTS_OPT_DISCOVERY_TIMEOUT=5

print ""
print "### iOS"
run_variant "ios_baseline_legacy" "$IOS_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=1 \
    DEVICESHOTS_OPT_HOTKEY_REFRESH=1 \
    DEVICESHOTS_OPT_TIFF=sync \
    DEVICESHOTS_OPT_PARALLEL_GETPROP=0 \
    DEVICESHOTS_OPT_DIRECT_XCODE=0 \
    DEVICESHOTS_OPT_DISCOVERY_TIMEOUT=10

run_variant "ios_skip_refresh" "$IOS_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=0 \
    DEVICESHOTS_OPT_HOTKEY_REFRESH=0 \
    DEVICESHOTS_OPT_TIFF=sync \
    DEVICESHOTS_OPT_DIRECT_XCODE=0

run_variant "ios_defer_tiff" "$IOS_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=0 \
    DEVICESHOTS_OPT_TIFF=deferred \
    DEVICESHOTS_OPT_DIRECT_XCODE=0

run_variant "ios_skip_tiff" "$IOS_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=0 \
    DEVICESHOTS_OPT_TIFF=skip \
    DEVICESHOTS_OPT_DIRECT_XCODE=0

run_variant "ios_direct_xcode" "$IOS_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=0 \
    DEVICESHOTS_OPT_TIFF=sync \
    DEVICESHOTS_OPT_DIRECT_XCODE=1

run_variant "ios_fast_discovery" "$IOS_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=1 \
    DEVICESHOTS_OPT_HOTKEY_REFRESH=1 \
    DEVICESHOTS_OPT_TIFF=sync \
    DEVICESHOTS_OPT_DIRECT_XCODE=0 \
    DEVICESHOTS_OPT_DISCOVERY_TIMEOUT=3

run_variant "ios_all_on" "$IOS_INDEX" \
    DEVICESHOTS_BENCH_INCLUDE_DISCOVERY=0 \
    DEVICESHOTS_OPT_HOTKEY_REFRESH=0 \
    DEVICESHOTS_OPT_TIFF=deferred \
    DEVICESHOTS_OPT_PARALLEL_GETPROP=1 \
    DEVICESHOTS_OPT_DIRECT_XCODE=1 \
    DEVICESHOTS_OPT_DISCOVERY_TIMEOUT=5

# --- Ranking ---
SUMMARY="$OUT_DIR/summary.json"
python3 - <<'PY' "$OUT_DIR" "$SUMMARY"
import json, sys, glob, os
out_dir, summary_path = sys.argv[1], sys.argv[2]
rows = []
for path in sorted(glob.glob(os.path.join(out_dir, "*.json"))):
    if path.endswith("summary.json"):
        continue
    with open(path) as f:
        data = json.load(f)
    name = os.path.basename(path).removesuffix(".json")
    platform = name.split("_", 1)[0]
    clip = (data.get("clipboardMs") or {}).get("median")
    paste = (data.get("pasteMs") or {}).get("median")
    tool = (data.get("deviceToolMs") or {}).get("median")
    disc = (data.get("discoveryMs") or {}).get("median")
    overhead = (data.get("deliveryOverheadMs") or {}).get("median")
    rows.append({
        "variant": name,
        "platform": platform,
        "device": data.get("deviceName"),
        "clipboard_median_ms": clip,
        "paste_median_ms": paste,
        "tool_median_ms": tool,
        "discovery_median_ms": disc,
        "delivery_overhead_median_ms": overhead,
        "opts": data.get("opts"),
        "include_discovery": data.get("includeDiscovery"),
    })

baselines = {r["platform"]: r for r in rows if r["variant"].endswith("baseline_legacy")}
ranked = []
for r in rows:
    base = baselines.get(r["platform"])
    delta = None
    if base and r["clipboard_median_ms"] is not None and base["clipboard_median_ms"] is not None:
        delta = base["clipboard_median_ms"] - r["clipboard_median_ms"]
    ranked.append({**r, "delta_vs_baseline_ms": delta})

# Bang-for-buck: largest absolute clipboard improvement for single-opt variants.
single_opts = [
    "skip_refresh", "defer_tiff", "skip_tiff", "parallel_getprop",
    "direct_xcode", "fast_discovery",
]
bang = []
for r in ranked:
    suffix = r["variant"].split("_", 1)[1] if "_" in r["variant"] else r["variant"]
    if suffix in single_opts and r["delta_vs_baseline_ms"] is not None:
        bang.append(r)
bang.sort(key=lambda x: x["delta_vs_baseline_ms"], reverse=True)

summary = {"rows": ranked, "bang_for_buck": bang, "out_dir": out_dir}
with open(summary_path, "w") as f:
    json.dump(summary, f, indent=2)

print("\n=== Bang for the buck (clipboard median vs legacy baseline) ===")
print(f"{'variant':40} {'platform':8} {'clipboard':>10} {'delta':>10} {'overhead':>10} {'discovery':>10}")
for r in bang:
    print(f"{r['variant']:40} {r['platform']:8} {r['clipboard_median_ms']:10.1f} {r['delta_vs_baseline_ms']:+10.1f} "
          f"{(r['delivery_overhead_median_ms'] or 0):10.1f} {(r['discovery_median_ms'] or 0):10.1f}")

print("\n=== Combined / baselines ===")
for r in ranked:
    suffix = r["variant"].split("_", 1)[1] if "_" in r["variant"] else ""
    if suffix in ("baseline_legacy", "all_on"):
        delta = r["delta_vs_baseline_ms"]
        delta_s = f"{delta:+.1f}" if delta is not None else "n/a"
        print(f"{r['variant']:40} clipboard={r['clipboard_median_ms']:.1f} ms  delta={delta_s}")
print(f"\nWrote {summary_path}")
PY

print ""
print "PASS: comparison complete → $SUMMARY"
