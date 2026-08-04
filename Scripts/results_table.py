#!/usr/bin/env python3
"""Generate the README results table from exported session records.

The README must not contain a hand-typed number (`docs/testing.md`), so this is the only path from
a measurement to a published figure. It reads the archival JSON the app writes — one
`<uuid>.session.json` per run, pulled off the device with `devicectl device copy from` — and mirrors
the aggregation rules in `docs/qoe-metrics.md`:

  * p90 is **nearest-rank**, matching `Percentile.nearestRank`.
  * Aggregate rebuffer ratio is **total stall over total watch**, not the mean of per-item ratios.
  * A per-arm figure is the **median of per-run values**, not a pooled percentile — three runs of
    26 items are three samples of the thing being compared, not 78.
  * The first item view of each run is the **warm-up** and is discarded (protocol step 5).
  * Skipped views (no watch time) are excluded from ratio aggregates but counted.

Usage:
    Scripts/results_table.py measurements/<dir> --profile "unthrottled Wi-Fi" [--subset hls|all|both]
"""
import argparse
import glob
import json
import math
import os
import sys
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(REPO, "FeedLab", "Content", "manifests", "short-form.json")

# The strategy table in the README is keyed by arm; this keeps the published order stable and
# independent of however the files happened to sort.
ARM_ORDER = [
    "baseline", "preload1", "preload3-capped", "preload3-uncapped", "window", "pool-unbounded",
]


def hls_item_ids():
    with open(MANIFEST) as handle:
        items = json.load(handle)["items"]
    return {item["id"] for item in items if ".m3u8" in item["url"]}


def nearest_rank(values, percentile):
    """Matches Percentile.nearestRank. Returns None for an empty sample rather than 0 — the
    distinction between "no data" and "zero" is load-bearing everywhere else in this rig."""
    if not values:
        return None
    ordered = sorted(values)
    index = math.ceil(percentile * len(ordered)) - 1
    return ordered[min(len(ordered) - 1, max(0, index))]


def median(values):
    return nearest_rank(values, 0.5)


def directional_ttff(records, order):
    """Startup split by scroll direction.

    The aggregate hides the only thing that separates the strategies. Every forward-only arm is
    fast forward and ~1 s slow backward; `window` is the sole arm that preloads backward and is
    fast both ways. Since the run script is half backward travel — far more than a real feed — an
    aggregate median reads as "window wins" when the honest statement is "window wins *on
    back-scroll*, and its forward figure is indistinguishable from the other preload arms."
    """
    forward, backward = [], []
    previous = None
    for record in records:
        position = order.get(record["itemID"])
        ttff = record.get("timeToFirstFrame")
        if previous is not None and position is not None and ttff is not None:
            (forward if position > previous else backward).append(ttff)
        if position is not None:
            previous = position
    return forward, backward


def run_stats(records):
    """One run's figures, over whichever subset of records it was handed."""
    watched = [r for r in records if r.get("watchDuration", 0) > 0]
    total_watch = sum(r["watchDuration"] for r in watched)
    total_stall = sum(r.get("totalStallDuration", 0) for r in watched)
    ttff = [r["timeToFirstFrame"] for r in records if r.get("timeToFirstFrame") is not None]
    dropped = [r["droppedFrames"] for r in records if r.get("droppedFrames") is not None]
    return {
        "views": len(records),
        "p90_ttff": nearest_rank(ttff, 0.9),
        "median_ttff": median(ttff),
        "rebuffer": (total_stall / total_watch) if total_watch else 0.0,
        "stalls": sum(r.get("stallCount", 0) for r in records),
        "skipped": len(records) - len(watched),
        # A view that rendered a frame and never played. Counted as its own population and never
        # folded into rebuffer ratio — the time was not rebuffering.
        #
        # `didStartPlayback` postdates the first device runs, and absent must mean *unknown* rather
        # than *false*: defaulting it to false reports every view of an older session as frozen,
        # which is both wrong and — since the frozen case is real — plausible enough to publish.
        "frozen": (
            sum(
                1 for r in records
                if r.get("timeToFirstFrame") is not None
                and not r["didStartPlayback"]
                and r.get("watchDuration", 0) > 0
            )
            if any("didStartPlayback" in r for r in records) else None
        ),
        "dropped": sum(dropped) if dropped else None,
    }


def manifest_order(path):
    """Item id → position, so a record sequence can be read as a scroll direction."""
    with open(path) as handle:
        return {item["id"]: index for index, item in enumerate(json.load(handle)["items"])}


def load(directory, subset, hls, order):
    """Runs grouped by arm, warm-up discarded, restricted to the requested subset."""
    runs = defaultdict(list)
    for path in sorted(glob.glob(os.path.join(directory, "*.session.json"))):
        with open(path) as handle:
            summary = json.load(handle)["summary"]
        records = summary["records"]
        if len(records) < 2:
            print(f"skipping {os.path.basename(path)}: {len(records)} views", file=sys.stderr)
            continue
        records = records[1:]  # warm-up
        if subset == "hls":
            records = [r for r in records if r["itemID"] in hls]
        if not records:
            continue
        stats = run_stats(records)
        stats["peak_mb"] = summary["peakMemoryBytes"] / 1048576
        forward, backward = directional_ttff(records, order)
        stats["forward_ttff"] = median(forward)
        stats["backward_ttff"] = median(backward)
        runs[summary["arm"]].append(stats)
    return runs


def spread(values, fmt):
    """A median with its observed range. The honesty rules require the spread beside every
    figure — two arms whose ranges overlap are indistinguishable, and the table has to show that
    rather than let a median imply a winner."""
    if not values or values[0] is None:
        return "—"
    low, high = min(values), max(values)
    if len(values) == 1:
        return fmt(values[0])
    return f"{fmt(median(values))} <sub>{fmt(low)}–{fmt(high)}</sub>"


def total(values):
    """A sum where one unknown makes the whole column unknown, rather than a smaller number that
    looks like a measurement."""
    values = list(values)
    return "—" if any(v is None for v in values) else str(sum(values))


def table(runs, profile, subset_label):
    ms = lambda v: f"{1000 * v:.0f}"
    ratio = lambda v: f"{v:.3f}"
    mb = lambda v: f"{v:.1f}"
    count = lambda v: f"{v:.0f}"

    lines = [
        f"**{subset_label}** · {profile} · median of runs, <sub>min–max</sub> beneath.",
        "",
        "| Arm | Runs | p90 TTFF (ms) | Median TTFF (ms) | ↓ forward | ↑ backward | Rebuffer ratio | Peak memory (MB) | Frozen |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    ordered = [a for a in ARM_ORDER if a in runs] + [a for a in sorted(runs) if a not in ARM_ORDER]
    for arm in ordered:
        rows = runs[arm]
        lines.append(
            f"| `{arm}` | {len(rows)} "
            f"| {spread([r['p90_ttff'] for r in rows], ms)} "
            f"| {spread([r['median_ttff'] for r in rows], ms)} "
            f"| {spread([r['forward_ttff'] for r in rows], ms)} "
            f"| {spread([r['backward_ttff'] for r in rows], ms)} "
            f"| {spread([r['rebuffer'] for r in rows], ratio)} "
            f"| {spread([r['peak_mb'] for r in rows], mb)} "
            f"| {total(r['frozen'] for r in rows)} |"
        )
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", help="directory of pulled *.session.json files")
    parser.add_argument("--profile", required=True, help="network profile, stated with every number")
    parser.add_argument("--subset", choices=["hls", "all", "both"], default="both")
    parser.add_argument("--manifest", default=MANIFEST,
                        help="manifest defining item order, for the direction split")
    args = parser.parse_args()

    order = manifest_order(args.manifest)
    hls = hls_item_ids()
    wanted = ["hls", "all"] if args.subset == "both" else [args.subset]
    labels = {
        "hls": "HLS items",
        "all": "Full corpus (HLS + progressive MP4)",
    }
    for index, subset in enumerate(wanted):
        runs = load(args.directory, subset, hls, order)
        if not runs:
            print(f"no runs found in {args.directory}", file=sys.stderr)
            return 1
        if index:
            print()
        print(table(runs, args.profile, labels[subset]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
