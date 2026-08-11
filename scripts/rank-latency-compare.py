#!/usr/bin/env python3
"""Rank latency A/B compare reports (from compare-capture-latency.sh).

Usage:
    python3 scripts/rank-latency-compare.py /path/to/outdir
"""

from __future__ import annotations

import glob
import json
import os
import sys

SINGLE_OPTS = (
    "skip_refresh",
    "defer_tiff",
    "skip_tiff",
    "parallel_getprop",
    "direct_xcode",
    "fast_discovery",
)

DIFFICULTY = {
    "skip_refresh": "easy",
    "defer_tiff": "easy",
    "skip_tiff": "easy",
    "parallel_getprop": "easy",
    "direct_xcode": "easy",
    "fast_discovery": "easy",
}


def platform_from_variant(name: str) -> str:
    if "_" not in name:
        return name
    return name.split("_", 1)[0]


def variant_suffix(name: str) -> str:
    if "_" not in name:
        return name
    return name.split("_", 1)[1]


def median(stats: dict | None) -> float | None:
    if not stats:
        return None
    value = stats.get("median")
    return float(value) if value is not None else None


def load_rows(out_dir: str) -> list[dict]:
    rows: list[dict] = []
    for path in sorted(glob.glob(os.path.join(out_dir, "*.json"))):
        if os.path.basename(path) == "summary.json":
            continue
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        name = os.path.basename(path).removesuffix(".json")
        rows.append(
            {
                "variant": name,
                "platform": platform_from_variant(name),
                "device": data.get("deviceName"),
                "clipboard_median": median(data.get("clipboardMs")),
                "paste_median": median(data.get("pasteMs")),
                "tool_median": median(data.get("deviceToolMs")),
                "discovery_median": median(data.get("discoveryMs")),
                "delivery_overhead_median": median(data.get("deliveryOverheadMs")),
                "opts": data.get("opts"),
                "include_discovery": data.get("includeDiscovery"),
            }
        )
    return rows


def attach_deltas(rows: list[dict]) -> list[dict]:
    baselines = {
        r["platform"]: r
        for r in rows
        if variant_suffix(r["variant"]) == "baseline_legacy"
    }
    ranked: list[dict] = []
    for row in rows:
        base = baselines.get(row["platform"])
        delta = None
        clip = row["clipboard_median"]
        base_clip = base["clipboard_median"] if base else None
        if base and clip is not None and base_clip is not None:
            delta = base_clip - clip
        ranked.append({**row, "delta_vs_baseline_ms": delta})
    return ranked


def bang_for_buck(ranked: list[dict]) -> list[dict]:
    bang: list[dict] = []
    for row in ranked:
        suffix = variant_suffix(row["variant"])
        if suffix not in SINGLE_OPTS:
            continue
        if row["delta_vs_baseline_ms"] is None:
            continue
        bang.append({**row, "difficulty": DIFFICULTY.get(suffix, "unknown")})
    bang.sort(key=lambda r: r["delta_vs_baseline_ms"], reverse=True)
    return bang


def fmt(value: float | None, width: int = 10, signed: bool = False) -> str:
    if value is None:
        return f"{'n/a':>{width}}"
    if signed:
        return f"{value:+{width - 1}.1f}"
    return f"{value:{width}.1f}"


def print_bang_table(bang: list[dict]) -> None:
    print("\n=== Bang for the buck (clipboard median vs legacy baseline) ===")
    header = (
        f"{'variant':40} {'platform':8} {'clipboard':>10} {'delta':>10} "
        f"{'overhead':>10} {'discovery':>10} {'tool':>10} {'difficulty':>10}"
    )
    print(header)
    for row in bang:
        print(
            f"{row['variant']:40} {row['platform']:8} "
            f"{fmt(row['clipboard_median']):>10} "
            f"{fmt(row['delta_vs_baseline_ms'], signed=True):>10} "
            f"{fmt(row['delivery_overhead_median']):>10} "
            f"{fmt(row['discovery_median']):>10} "
            f"{fmt(row['tool_median']):>10} "
            f"{row['difficulty']:>10}"
        )


def print_combined(ranked: list[dict]) -> None:
    print("\n=== Combined / baselines ===")
    for row in ranked:
        suffix = variant_suffix(row["variant"])
        if suffix not in ("baseline_legacy", "all_on"):
            continue
        delta = row["delta_vs_baseline_ms"]
        delta_s = f"{delta:+.1f}" if delta is not None else "n/a"
        clip = row["clipboard_median"]
        clip_s = f"{clip:.1f}" if clip is not None else "n/a"
        def plain(value: float | None) -> str:
            return "n/a" if value is None else f"{value:.1f}"

        print(
            f"{row['variant']:40} clipboard={clip_s} ms  delta={delta_s}  "
            f"overhead={plain(row['delivery_overhead_median'])}  "
            f"discovery={plain(row['discovery_median'])}  "
            f"tool={plain(row['tool_median'])}"
        )


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/outdir", file=sys.stderr)
        return 1

    out_dir = sys.argv[1]
    if not os.path.isdir(out_dir):
        print(f"FAIL: not a directory: {out_dir}", file=sys.stderr)
        return 1

    rows = load_rows(out_dir)
    if not rows:
        print(f"FAIL: no compare JSON reports in {out_dir}", file=sys.stderr)
        return 1

    ranked = attach_deltas(rows)
    bang = bang_for_buck(ranked)

    summary_path = os.path.join(out_dir, "summary.json")
    summary = {
        "out_dir": out_dir,
        "rows": ranked,
        "bang_for_buck": bang,
        "difficulty": DIFFICULTY,
    }
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    print_bang_table(bang)
    print_combined(ranked)
    print(f"\nWrote {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
