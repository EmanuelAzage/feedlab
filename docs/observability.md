---
type: spec
title: Observability — HUD, Dashboard, Signposts, Export
description: How measurements are surfaced live, charted after the fact, exported, and captured as README screenshots
status: living
tags: [observability, hud, charts, signposts, screenshots]
timestamp: 2026-08-05T00:00:00Z
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

**Measured 2026-08-04 — free on startup, not free on memory.** `window`, 6 runs alternating HUD off
and on so the pair shares any drift, 51–53 pooled item views per condition:

| | Median TTFF | Peak memory |
|---|---|---|
| HUD off | 97 ms | 16.5 MB <sub>16.4–16.7</sub> |
| HUD on | 94 ms | 18.5 MB <sub>18.4–18.7</sub> |
| delta | **−3 ms** | **+2.0 MB** |

The startup delta is 3 ms in the *faster* direction — noise, and the criterion passes. Sampling at
4 Hz rather than subscribing to the event stream is doing its job.

The memory cost is real: **+2.0 MB with non-overlapping ranges** across three runs each. Peak memory
is a published metric, so **HUD-on and HUD-off runs must never be pooled for it**. Nothing in a
session file records whether the HUD was visible, which is a gap — the pairing above is recovered
from run order. Until that is stored, a HUD-on run is only identifiable from the batch log that
produced it.

One near-miss worth recording: `-hud 1` set the flag and nothing acted on it at launch, because
`syncHUDVisibility()` only ran when the debug menu closed. The HUD-on half would have run with no HUD
and the criterion would have passed for the worst possible reason — the thing under test being
absent. The runner now asserts the HUD is on screen when it asked for one, and absent when it did
not.

**Implemented M4.** Off by default, toggled from the debug menu — off has to be the baseline, since the
criterion above can only be checked against runs without it. The timer is added to `RunLoop.Mode.common`,
or it would freeze during a scroll drag and hide the numbers exactly when they change fastest. The overlay
is `allowsHitTesting(false)`: it must never intercept the gestures whose effects it is measuring. Gated on
`FEEDLAB_TOOLS` and verified absent from `Release` by symbol count.

Reading the bitrate row: it shows **observed / indicated**, and observed is download *throughput*, so on a
fast link it legitimately reads far above the media rate (66930k / 3216k was a real first reading). The row
matters when observed falls *below* indicated — see `ios-learning-notes.md`.

**Fixed M6, before the screenshots.** The row used to truncate on a fast link — `135844k / 321…` was a real
reading — dropping the indicated figure, which is the half that makes the row mean anything. Six digits of
kbps do not fit, so the formatter now scales past `k`: `135.8M / 3.2M`. Four characters per side holds at any
throughput, and a screenshot no longer advertises a broken instrument.

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

Session data exports as JSON (full records) and CSV (flat, per item) via the share sheet. CSV is the
spreadsheet path; JSON is the archival one, and it is what makes a run re-derivable if a metric
definition changes — which has already happened once, when `didStartPlayback` let the frozen-frame
count be reconstructed from runs performed before the metric existed.

**The README's results table is generated, not typed.** `Scripts/results_table.py` reads the archival
session records pulled off the device and emits the table markdown directly, so no number reaches the
README by transcription. It reads the persisted JSON rather than the share-sheet CSV for a practical
reason — sessions come off the device over USB with `devicectl`, while the CSV requires a human and a
share sheet — and it restates the aggregation rules from `qoe-metrics.md` rather than inventing its
own: nearest-rank p90, total-over-total rebuffer ratio, median of per-run values, warm-up item
discarded. Where a field is absent because the session predates it, the column prints `—`; defaulting
it would produce a number that is wrong and plausible at the same time.

## Screenshot plan (for README)

**Captured by a UI test, not by hand** — `FeedLabRunner/ScreenshotRun.swift`, on the device, so they
are reproducible and so the figures in them are device figures. The HUD in particular renders live
session numbers, and a simulator capture would put simulator numbers in the README.

- [x] `feed.png` — the feed playing, HUD off (it's still a real app).
- [x] `hud.png` — HUD active mid-session, arm name visible.
- [x] `dashboard-tradeoff.png` — the startup-vs-smoothness scatter. **Hero image.** Shot against the
      *constrained* corpus deliberately: unthrottled, every rebuffer ratio is 0.000 and the scatter
      collapses to a line, so the chart whose entire subject is a tradeoff would show none.
- [x] `dashboard-memory.png` — peak memory by arm, including the unbounded control.
- [x] `debug-menu.png` — arm selection and build configuration.
- [ ] `instruments-signposts.png` — Points of Interest trace with memory track.

Two defects were found by looking at the output rather than by any test, which is the argument for
capturing screenshots as a routine step rather than once at the end:

- **The scatter's point labels collided** into an unreadable smear whenever arms clustered — which is
  what happens whenever a strategy works. Removed; the colour legend beneath already names them.
- **The memory chart rendered empty**, because `map(Double.init)` over `[UInt64]` resolved to
  `Double.init(bitPattern:)`. See `decisions.md`.

Charts also need a settle delay before capture: Swift Charts lays out lazily inside a scroll view,
and a chart photographed too early shows axes with no marks — indistinguishable from an arm with no
data.

Store under `docs/images/` (or `Screenshots/`), referenced from the README and from this doc. Keep them current: if a chart's shape changes materially, retake the screenshot in the same change.
