---
type: plan
title: FeedLab Build Plan
description: Milestones M1-M6 with acceptance criteria, sized for incremental sessions
status: living
tags: [plan, milestones]
timestamp: 2026-08-02T21:38:53Z
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
- [ ] `FeedCell` owning `AVPlayerLayer`; attach/detach on becoming current.
- [ ] Visibility-driven play/pause; looping; asset load and item prep off-main with cancellation on fast scroll.
- [x] Unit tests: pool capacity, wait-on-exhaustion, teardown. *(10 tests / 13 cases against fakes and a fake clock — no device, no stream, no real time.)*
- [x] Two-tier preparation verified empirically; findings in `playback-engine.md` and `ios-learning-notes.md`.
- **Accept:** scroll through 20 items with pool capacity 3 — video plays only on the current item, no wrong-video-in-cell flashes, no player leak (occupancy returns to 0 when idle), main thread free of asset work (verify in Instruments).

## M3 — Instrumentation and metrics
- [ ] `PlaybackEvent` vocabulary; `PlaybackObserver` (KVO on `timeControlStatus`, `reasonForWaitingToPlay`, `isReadyForDisplay`, item status; notifications for stalls, access/error log entries, end-of-item).
- [ ] Pure `MetricsEngine` folding events → `PlaybackRecord`; session aggregation with p90.
- [ ] Full unit suite per `testing.md` (this is the milestone where test coverage is earned).
- **Accept:** every metric in `qoe-metrics.md` computed for each item; metrics tests pass; `Metrics/` imports no AVFoundation.

## M4 — Live HUD
- [ ] HUD overlay per `observability.md`, ≤4 Hz updates, arm name prominent, debug-only.
- [ ] Memory sampler (resident size) feeding session peak.
- **Accept:** HUD numbers move sensibly under Network Link Conditioner throttling; enabling the HUD doesn't measurably change TTFF (compare a run with it off).

## M5 — Preload strategies and experiment harness
- [ ] `PreloadStrategy` protocol + the four strategies + `pool-unbounded` control; `ArmRegistry`; arm selection resets the session.
- [ ] `SessionStore` persistence; strategy unit tests.
- **Accept:** switching arms visibly changes preparation behavior (observable in signposts/HUD); strategy index math fully unit-tested; sessions survive app relaunch.

## M6 — Dashboard, measurement runs, publication
- [ ] Swift Charts dashboard (all charts in `observability.md`), CSV/JSON export, `os_signpost` intervals.
- [ ] Measurement runs per `testing.md`: every arm × 2 network profiles × ≥3 runs, on a physical device.
- [ ] Screenshots per the screenshot plan, including an Instruments trace.
- [ ] README: what/why, architecture diagram, results table generated from the CSV export, methodology and its limits, content attribution.
- **Accept:** a reader can see the startup-vs-smoothness tradeoff from the README alone; every published number traces to an exported run; the honesty rules in `experiment-harness.md` are satisfied.

## Stretch
- MetricKit integration (real-world launch/hang/scroll-hitch metrics).
- A "hostile network" profile that flips between good and bad mid-session.
- Adaptive strategy that switches preload depth based on observed scroll velocity — then measure whether it actually beats the fixed strategies.
- **SwiftUI feed surface as an experiment arm**: a second implementation (`ScrollView`/`LazyVStack` with iOS 17 paging APIs) behind the same coordinator protocol, measured against the UIKit surface for TTFF, dropped frames, and scroll hitches. Nobody has published good data on whether the rendering layer costs anything on a video feed.
