---
type: spec
title: Observability — HUD, Dashboard, Signposts, Export
description: How measurements are surfaced live, charted after the fact, exported, and captured as README screenshots
status: living
tags: [observability, hud, charts, signposts, screenshots]
timestamp: 2026-08-04T02:10:00Z
related: [qoe-metrics.md, experiment-harness.md, product-spec.md]
---

# Observability

Three surfaces: a **live HUD** (what's happening now), a **dashboard** (what happened across arms), and **signposts** (what Instruments sees). All three are screenshot targets for the README — the project's legibility depends on them.

## Live HUD

Compact overlay, debug builds only, toggleable. Two blocks:

**Current item** — TTFF (ms), stalls (count / total seconds), rebuffer ratio so far, observed vs. indicated bitrate (kbps), bitrate switches, dropped frames.
**Session** — arm name (prominent), items viewed, mean and p90 TTFF, aggregate rebuffer ratio, pool occupancy (`2/3`), peak resident memory (MB).

Design rules: monospaced digits so numbers don't jitter; update at ≤4 Hz (a HUD that re-renders every frame perturbs what it measures); semi-transparent, never covering the video center; arm name always visible so any screenshot is self-documenting.

**Sample, don't throttle.** The HUD pulls current aggregate state on a 4 Hz timer rather than subscribing to
the event stream and throttling it. Pull decouples HUD cost from event *rate* entirely, so a stall storm —
precisely when the HUD is most interesting — cannot turn the HUD into a load source that perturbs the
measurement. A throttled push still pays per-event delivery cost before discarding.

The M4 acceptance criterion (enabling the HUD must not measurably change TTFF) is the check on this.

**Implemented M4.** Off by default, toggled from the debug menu — off has to be the baseline, since the
criterion above can only be checked against runs without it. The timer is added to `RunLoop.Mode.common`,
or it would freeze during a scroll drag and hide the numbers exactly when they change fastest. The overlay
is `allowsHitTesting(false)`: it must never intercept the gestures whose effects it is measuring. Gated on
`FEEDLAB_TOOLS` and verified absent from `Release` by symbol count.

**Known issue for the screenshot plan:** with a fast link the bitrate row truncates — `135844k / 321…` was
a real reading, because observed throughput reaches six digits of kbps. Before `hud.png` is captured for the
README the row needs to fit its own numbers, or the screenshot advertises a broken instrument. Fix in M6
alongside the screenshots, not before: throttled runs are where the row is legible anyway, and that is the
condition worth photographing.

Reading the bitrate row: it shows **observed / indicated**, and observed is download *throughput*, so on a
fast link it legitimately reads far above the media rate (66930k / 3216k was a real first reading). The row
matters when observed falls *below* indicated — see `ios-learning-notes.md`.

## Dashboard (SwiftUI + Swift Charts)

Reachable from the debug menu; renders stored sessions grouped by arm.

1. **TTFF by arm** — bar chart of median with p90 marked. The headline chart.
2. **TTFF distribution** — per-item scatter or histogram; shows the long tail a mean hides.
3. **Rebuffer ratio by arm** — bar chart, aggregate ratio.
4. **Startup vs. smoothness** — scatter, p90 TTFF (x) against rebuffer ratio (y), one point per arm. The tradeoff in one picture; make this the README's hero image.
5. **Peak memory by arm** — bar chart; where `pool-unbounded` earns its keep.
6. **Bitrate over time** — line chart, observed vs. indicated for a selected session; shows ABR behavior and switch density.
7. **Session table** — sortable raw records, with export.

Every chart displays its network profile and run count in the subtitle so a screenshot can't be misread out of context.

## Signposts and Instruments

Emit `os_signpost` intervals (`OSSignposter`) around: asset load, item prepare, player acquire (the pool-wait interval), attach, and first frame. This makes a Time Profiler / Points of Interest trace directly readable and gives a second, independent view of pool contention.

Deliverable: one Instruments screenshot in the README showing the Points of Interest track alongside memory — a native-engineer signal that a pure-Swift portfolio repo usually lacks.

## Export

Session data exports as JSON (full records) and CSV (flat, per item) via the share sheet. The README's results table is generated from an exported CSV, not typed by hand — no transcription drift between what was measured and what's published.

## Screenshot plan (for README)

Captured on device, light and dark:
- `feed.png` — the feed playing, HUD off (it's still a real app).
- `hud.png` — HUD active mid-session, arm name visible.
- `dashboard-tradeoff.png` — the startup-vs-smoothness scatter. **Hero image.**
- `dashboard-ttff.png` — TTFF by arm with p90.
- `dashboard-memory.png` — peak memory by arm, including the unbounded control.
- `instruments-signposts.png` — Points of Interest trace with memory track.

Store under `docs/images/` (or `Screenshots/`), referenced from the README and from this doc. Keep them current: if a chart's shape changes materially, retake the screenshot in the same change.
