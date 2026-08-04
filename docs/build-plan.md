---
type: plan
title: FeedLab Build Plan
description: Milestones M1-M6 with acceptance criteria, sized for incremental sessions
status: living
tags: [plan, milestones]
timestamp: 2026-08-04T23:00:00Z
related: [playback-engine.md, qoe-metrics.md, observability.md, testing.md]
---

# Build Plan

Milestones are ordered but **not time-boxed** — this is built incrementally across short sessions. Each milestone ends in a committed, compiling, test-passing state, so work can stop anywhere without leaving the repo broken. Prefer finishing a milestone's acceptance criteria over starting the next.

## M1 — Feed shell
- [x] Xcode project, Swift 6, iOS 17+, SwiftLint, folder structure per `architecture.md`. XcodeGen `project.yml` is the source of truth (`decisions.md`).
- [x] Content manifest loading with license/attribution validation; `short-form.json` populated from `content-sources.md` (22 items; every URL probed before commit).
- [x] Vertical paging `UICollectionView` (compositional layout), full-screen cells showing title/placeholder — **no playback yet**.
- [x] Debug menu skeleton — content summary, per-source Credits screen (satisfies the attribution surface required by `content-sources.md`), and build configuration with an "unoptimized, not publishable" warning. Reached by an on-screen button or a shake. Contains **only controls whose subsystem exists**; arm selection, HUD/signpost toggles and session controls arrive with M3–M5 rather than as inert placeholders.
- **Accept:** smooth paging scroll over ≥20 manifest items — *verified on simulator: 21 swipes forward reaches the last item, 5 back lands exactly on index 16, and the bottom-anchored label sits at the same y on every page, so pages land flush with no cumulative drift*; manifest missing attribution fails validation (unit test) — *done, plus every other required field, whitespace-only values, duplicate ids, non-HTTPS urls, and malformed JSON*.

## M2 — Playback core
- [x] `PlayerProviding`/`PlayerItemProviding` wrappers; `PlayerPool` (actor) with fixed capacity, FIFO waiters, cancellable acquire, measured wait, full teardown, and `drain()`.
- [x] `FeedCell` owning `AVPlayerLayer`; attach/detach on becoming current, via the `PlayerRenderTarget` ordering rule.
- [x] Visibility-driven play/pause; looping (seek-to-zero); asset load and item prep off-main with cancellation on fast scroll. Intent fires on **settle**, not continuously — see `decisions.md`.
- [x] Unit tests: pool capacity, wait-on-exhaustion, teardown. *(10 tests / 13 cases against fakes and a fake clock — no device, no stream, no real time.)*
- [x] Two-tier preparation verified empirically; findings in `playback-engine.md` and `ios-learning-notes.md`.
- **Accept:** scroll through 20 items with pool capacity 3 — video plays only on the current item, no wrong-video-in-cell flashes, no player leak (occupancy returns to 0 when idle), main thread free of asset work (verify in Instruments).
  - *Verified on simulator 2026-08-02:* sequential playback with `occupancy 0, free 1` logged after every release — one player serves the whole session. A 20-swipe fast scroll prepared **nothing** in between: only the initial index and the settled index ever acquired. Correct item rendered in the correct cell at rest.
  - *Verified on device 2026-08-02* (iPhone 12 Pro, iOS 26.5.2, `Measure` config, 36 s Time Profiler trace under continuous manual scrolling): **zero** entries in `potential-hangs` (>250 ms threshold); main thread used ~422 ms CPU across 36.4 s. The only media symbols on main-thread stacks were notification delivery and property reads — `CMNotificationCenterPostNotification` (11 samples), `__avplayeritem_fpItemNotificationCallback_block_invoke` (5), `-[AVPlayerItem isPlaybackBufferEmpty]` (1) — totalling ~35 ms. **Absent:** `-[AVURLAsset initWithURL:options:]`, `-[AVPlayerItem initWithAsset:]`, any `loadValues*`. Asset and item construction do not touch the main thread.
  - *Not a published number:* single run, no fixed scroll script, unthrottled network. It clears the criterion; it does not enter the README.

## M3 — Instrumentation and metrics
- [x] `PlaybackEvent` vocabulary — including `.userPaused`/`.userResumed`, which the pause-exclusion rule in `qoe-metrics.md` requires whether or not the gesture exists yet.
- [x] `PlaybackObserver` (KVO on `timeControlStatus`, `reasonForWaitingToPlay`, `isReadyForDisplay`; notifications for access/error log entries and end-of-item), stamping timestamps at the callback, with `invalidate()` before release. Delivery via `PlaybackEventPipe` (`AsyncStream`) into `SessionRecorder`.
- [x] Pure `MetricsEngine` folding events → `PlaybackRecord`; session aggregation with p90 (nearest-rank, stated in `SessionSummary`).
- [x] Full unit suite per `testing.md` — 62 tests across 5 suites, including the `Metrics/` purity guard.
- [x] **Playback gestures** (specified in `product-spec.md`, previously missing from every milestone): tap → play/pause emitting `.userPaused`/`.userResumed`, double-tap → seek to start, long-press → source info. Landed here because the pause events are a metrics correctness requirement, not a UI nicety. *Verified end to end: an item on screen ~12.5 s with a ~4 s deliberate pause recorded `watch 8.80s`.*
- [x] Minimal scrubber with elapsed/duration (`product-spec.md`). Read-only, driven by a 4 Hz periodic time observer removed on teardown alongside every other registration. Deliberately not draggable: seeking mid-run is something the measurement protocol has no way to account for.
- **Accept:** every metric in `qoe-metrics.md` computed for each item; metrics tests pass; `Metrics/` imports no AVFoundation.
  - *Verified end to end on simulator 2026-08-02*, real playback producing e.g. `apple-bipbop-fmp4: ttff 356 ms, watch 5.40s, stalls 0, ratio 0.000, switches 3` — observation, callback-site stamping, ordered delivery and the pure fold all working together. Switch counts of 2/0/3 across three streams confirm ABR detection is real rather than constant.
  - *Every **per-item** metric in `qoe-metrics.md` is now computed.* Peak memory is a **session** metric attributed to the arm rather than the item, and belongs to M4's sampler — so M3's criterion is met.

## M4 — Live HUD
- [x] HUD overlay per `observability.md`, 4 Hz **sampled** (not throttled push), arm name prominent, `FEEDLAB_TOOLS`-only and verified absent from `Release` by symbol count. Off by default, toggled from the debug menu.
- [x] Memory sampler feeding session peak. `phys_footprint` at 5 Hz, running whether or not the HUD is visible. Reports **peak observed**, never true peak — a spike between samples is invisible, so the figure is a lower bound.
- [x] **On-device confirmation of the buffer/memory relationship — resolved by revision.** The macOS probe (`playback-engine.md`) showed ~91 MB vs ~1.5 MB for four attached items at default vs 5 s cap, but macOS `phys_footprint` is not iOS memory and it was a single run. Re-measure on device with the sampler before any claim about capping reaches the README.
  - *Answered 2026-08-03 (iPhone 12 Pro, `Measure`, unthrottled, n=3 per arm, matched dwell):* **capping made no measurable difference.** `preload3-capped` and `preload3-uncapped` both peaked at a median 14.1 MB, ranges 14.1–14.2, fully overlapping — against a macOS probe predicting ~60×. The strategy table is revised in [playback engine](playback-engine.md): the cap stays as an experiment variable, not as a recommendation.
  - *Unblocked 2026-08-03:* the comparison was not previously expressible — `PreloadNext3Capped` was the only deep-preload arm, so there was nothing to compare it against. `preload3-uncapped` now holds depth and pool capacity fixed and varies only the buffer configuration, which is what isolates the lever.
- **Accept:** HUD numbers move sensibly under Network Link Conditioner throttling; enabling the HUD doesn't measurably change TTFF (compare a run with it off); the capped-vs-uncapped footprint difference is confirmed on device or the strategy table is revised.
  - *Third criterion met 2026-08-03* — by revision rather than confirmation, which the criterion explicitly allows.
  - *First criterion met 2026-08-04:* HUD numbers move sensibly under a DSL 2 Mbps profile — startup rises from ~110 ms to seconds on the unpreloaded arms, rebuffer ratio becomes non-zero for the first time, and the bitrate row tracks ABR downswitching from 6725 kbps into the 41–701 kbps range.
  - *Second criterion met 2026-08-04:* the HUD-perturbation pair — `window`, 6 runs alternating, 51–53 pooled item views per condition — reports **median TTFF 94 ms with the HUD on against 97 ms with it off**, a 3 ms delta in the faster direction. Enabling the HUD does not measurably change startup. It does cost **+2.0 MB of peak footprint** (18.5 vs 16.5 MB, non-overlapping ranges), which is not what the criterion asks about but is published elsewhere, so the two populations must not be pooled for memory. Detail in [observability](observability.md).
  - **M4 complete.**

## M5 — Preload strategies and experiment harness
- [x] `PreloadStrategy` protocol + the four strategies + `pool-unbounded` control; `ArmRegistry`; arm selection resets the session **and returns to the first item** (the run protocol needs the same item order per arm, or the discarded warm-up item is not the same item).
- [x] Planner wired into `FeedCoordinator` — a three-state machine per index (`warm` → `backed` → `current`) with reconciliation against the plan. `backed → current` is the only synchronous transition, and it is the whole preload payoff.
- [x] `SessionStore` persistence; strategy unit tests. *(109 tests across 10 suites.)*
- **Accept:** switching arms visibly changes preparation behavior (observable in signposts/HUD); strategy index math fully unit-tested; sessions survive app relaunch.
  - *Verified on simulator 2026-08-03, in the HUD as the criterion asks:* under `baseline` the launch prepares index 0 only and the HUD reads `pool 1/3` — identical to pre-arm behaviour, so the control really is the absence of a strategy. Switching to `preload3-capped` reads `ARM PRELOAD3-CAPPED · pool 4/4`, with indices 1–3 preloaded to tier 2 at launch and the next index preloaded on each settle. A promoted (preloaded) item reported `ttff 68 ms` against `428 ms` for a cold first item, and `pool wait 0 ms` — no acquire, because the player was already held.
  - *Sessions survive relaunch:* asserted by unit test over a second store instance on the same directory, and confirmed on simulator — backgrounding sealed a 3-item session to `Application Support/FeedLab/Sessions/`, records and raw events both.
  - *Not numbers:* single unthrottled simulator runs with a warm CDN cache. They demonstrate the arms differ; the magnitudes are M6's job on a device.

## M6 — Dashboard, measurement runs, publication
- [x] Swift Charts dashboard (all charts in `observability.md`), CSV/JSON export, `os_signpost` intervals.
  - *Signposts verified 2026-08-03:* the signposted first-frame interval and the computed `timeToFirstFrame` both read **492 ms** on the same run — two independent paths agreeing, which is the whole reason to emit them.
  - *Dashboard reports the median of per-run p90s*, not the pooled percentile, per the run protocol; a test pins the distinction. Arms with no runs are absent rather than zero-height.
- [x] Measurement runs per `testing.md`: every arm × 2 network profiles × ≥3 runs, on a physical device.
  - *Complete 2026-08-04:* 36 runner-driven runs on the HLS-only corpus — 18 unthrottled Wi-Fi at 5 s dwell, 18 under DSL 2 Mbps at 10 s dwell — plus 6 for the HUD pair. Raw sessions in `measurements/`, tables generated by `Scripts/results_table.py`. Headline: preload cuts forward startup 9× unthrottled and ~100× constrained; depth beyond one item is free on a fast link and *harmful backward* on a slow one; and the rebuffer column ranks the arms backwards unless read beside views and frozen counts, because the arms posting 0.000 are the ones that never started playback.
  - *3G was tried and rejected* as the constrained profile: at 780 kbps `baseline` produced zero first frames across 7 recorded views, so startup was unmeasurable. Recorded in `qoe-metrics.md` as a floor observation rather than a comparison.
  - *Done 2026-08-03:* `preload3-capped` and `preload3-uncapped`, unthrottled Wi-Fi, n=3 each, alternating, matched pace. Settled M4's memory question (see above).
  - *Device pipeline established:* `Measure` build installs via `devicectl`, the arm and corpus chosen by launch argument for a genuine cold start per run, sessions pulled back over USB with `devicectl device copy from --domain-type appDataContainer`. A run is one command; a batch of 18 is unattended.
  - *Comparisons are reported over the HLS corpus*, per `decisions.md`. The "full-corpus figures alongside" half of that obligation was dropped when the measurement corpus became HLS-only; the README states the exclusion and cites the measured 27% instead.
- [ ] Screenshots per the screenshot plan, including an Instruments trace.
- [x] README: what/why, architecture diagram, results table generated from the runs, methodology and its limits, content attribution.
  - *Done 2026-08-04* apart from images: both results tables, the direction split, the analysis of what the numbers say, and a limits section covering the HLS-only corpus, warm laps, XCUITest overhead, peak-observed memory, and the not-an-A/B-test caveat.
- **Accept:** a reader can see the startup-vs-smoothness tradeoff from the README alone; every published number traces to an exported run; the honesty rules in `experiment-harness.md` are satisfied.

## Stretch
- MetricKit integration (real-world launch/hang/scroll-hitch metrics).
- A "hostile network" profile that flips between good and bad mid-session.
- Adaptive strategy that switches preload depth based on observed scroll velocity — then measure whether it actually beats the fixed strategies.
- **SwiftUI feed surface as an experiment arm**: a second implementation (`ScrollView`/`LazyVStack` with iOS 17 paging APIs) behind the same coordinator protocol, measured against the UIKit surface for TTFF, dropped frames, and scroll hitches. Nobody has published good data on whether the rendering layer costs anything on a video feed.
