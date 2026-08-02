---
type: decision-log
title: FeedLab Decisions
description: ADR-lite log of technical choices and their rationale
status: living
tags: [decisions, adr, dependencies]
timestamp: 2026-08-02T22:15:35Z
related: [architecture.md, playback-engine.md]
---

# Decisions

Add a dated entry for every non-obvious choice. Newest first.

## 2026-08-02 — Asset work lives in a `nonisolated` type, not in the coordinator's task
`FeedCoordinator` is `@MainActor`, and an unstructured `Task { }` created in a main-actor context
**inherits that isolation**. Asset and item construction placed directly in that task therefore ran on the
main thread, violating the architecture's central threading rule. Playback still worked — `await` releases
the actor while AVFoundation does its I/O elsewhere — which is exactly what made the mistake invisible;
it was found by logging `Thread.isMainThread`, not by anything misbehaving.

`ItemPreparer.prepare` is `nonisolated async`, so per SE-0338 it runs on the global concurrent executor
rather than the caller's actor, which is what actually moves the work off main. A debug `assert` on
`!Thread.isMainThread` guards the invariant, so a future regression fails loudly in development instead of
becoming a scroll hitch that only shows up in a device trace.

## 2026-08-02 — Playback intent fires on scroll *settle*, not continuously
The feed tracks the current index continuously for display, but only a settled page starts playback.
Continuous intent would acquire and release a player at every rounding boundary during a drag, thrashing the
pool in exactly the fast-scroll case the rig is built to study, and would leave `t0` for time-to-first-frame
ambiguous — "became current" would fire repeatedly for items the user never stopped on. Settle gives one
unambiguous `t0` per viewed item.

Measured consequence: a 20-swipe fast scroll prepares **nothing** in between — only the departure and
arrival indices ever acquire a player. Preparing items *ahead* is deliberately not this type's job; that is
`PreloadStrategy` (M5), and keeping it out here means the M2 baseline is genuinely "no preload" rather than
an accidental policy nobody chose.

Three settle events must all be handled — `scrollViewDidEndDecelerating`, `scrollViewDidEndDragging` with
`willDecelerate == false`, and `scrollViewDidEndScrollingAnimation`. Missing any one leaves playback
silently not starting for pages that came to rest that way.

## 2026-08-02 — Audio session set to `.playback` explicitly
The default `.soloAmbient` category is silenced by the ringer switch, and a silenced session can mean the
audio path does no work. Since audio decode is part of the workload under measurement, leaving the default
would let two runs of the same arm differ by whether the device happened to be muted — a variance source
with nothing to do with preload strategy. `.playback` with `.moviePlayback` holds the workload constant and
matches feed convention.

## 2026-08-02 — `acquire()` throws so a blocked wait can be cancelled
The original `PlayerPooling` sketch had a non-throwing `acquire() async`. That is wrong for a feed: a fast
scroll past an item whose acquire is still queued must be able to abandon the wait, and a continuation that
is never resumed leaks the task forever. `acquire()` now throws `CancellationError` when the calling task is
cancelled, and the pool removes the stranded waiter. Cost is a `try` at every call site; the alternative was
a pool that quietly accumulates suspended tasks during exactly the scroll pattern the rig is built to study.

## 2026-08-02 — Teardown responsibility is split three ways, deliberately
`release()` cannot do the whole job. The pool resets player state; the **cell** nils `layer.player` on the
main actor *before* releasing, because layer work is main-thread-only and detaching late is what puts a
frame of the wrong video in the wrong cell; the **instrumentation layer** removes its own KVO and
notification registrations, because only it knows what it registered. Concentrating all three in the pool
would require the pool to know about layers and observers, coupling it to both the UI and the metrics
layers. The split is recorded as a table in `playback-engine.md` because "all three must happen" is the
invariant, and a reader needs to see where each lives.

## 2026-08-02 — Domain enums mirror AVFoundation rather than re-exporting it
`PlayerTimeControlStatus`, `PlayerWaitingReason`, `PlayerItemStatus` restate their AVFoundation
counterparts. The duplication is deliberate: it keeps `PlayerProviding` free of AVFoundation, so fakes are
trivial and the same types can travel into the event vocabulary that `Metrics/` consumes without dragging
the framework across the boundary `architecture.md` forbids. The mapping lives in one adapter file and is
the only place a framework enum appears.

## 2026-08-01 — No app-wide presentation architecture (no MVVM/VIPER/TCA)
MVVM, VIPER and TCA are presentation architectures; they pay off when the hard problem is deriving view
state, coordinating navigation, or managing a large UI state graph. FeedLab has four screens, one navigation
edge, and a feed whose entire presentation state is *which index is current*. The hard state here is domain
state — player lifecycle, preparation tiers, pool occupancy, the stall/TTFF state machine — and it already
has an architecture: functional core plus ports and adapters. Adding a presentation framework on top would
add ceremony at the layer with the least state.

TCA specifically: its strongest argument is exhaustive deterministic testing of a state machine with
effects, and **we already have the valuable half of that**. `MetricsEngine` is a reducer —
`(State, Event) -> State` folding `[PlaybackEvent]` with injected timestamps — so we get determinism and
synthetic-edge-case testing with no dependency, and without an effect system anywhere near the AVFoundation
boundary that `architecture.md` forbids the tested layer from touching. The repo stays dependency-free,
which is also a better signal for its audience than a framework import.

Where a lightweight `@Observable` type *is* justified, all SwiftUI and none needing a framework: the
dashboard (M6, genuine view-state derivation), the HUD (M4, derived state under a hard 4 Hz budget), and the
debug menu once arm selection and session control exist (M5).

## 2026-08-01 — No Combine; raw KVO/NotificationCenter stamped at the callback, delivered via AsyncStream
The deciding constraint is not ergonomics but timestamp fidelity — see the measurement-discipline section of
`qoe-metrics.md`. Once the clock is read synchronously inside the observation callback, the delivery
mechanism no longer affects any number, and Combine's convenience buys little against three costs:

1. **Swift 6 strict concurrency.** Combine predates it and creates real `Sendable` friction across
   isolation boundaries. `AsyncStream` into an actor or serial context expresses the same thing cleanly.
2. **One cancellation model.** `playback-engine.md` already commits to structured-concurrency tasks
   cancelled on fast scroll. Combine would add `AnyCancellable` alongside `Task` cancellation — two systems
   to get right inside `PlayerPool.release()`, which is exactly where the classic leaked-KVO-on-a-recycled-
   player bug lives.
3. **Direction of travel.** Apple's newer APIs are async/await-first and `@Observable` has replaced
   `ObservableObject` for view binding, so even the SwiftUI layer has no need of it.

Being explicit at this layer is also the point of the project: `player.publisher(for: \.timeControlStatus)`
hides the observation surface the rig exists to study.

Not claimed: that Combine's KVO-publisher overhead is material at our event rates. That is a directional
argument, unmeasured. Reversible either way — the seam is `PlaybackObserver`, so changing delivery touches
one type.

## 2026-08-01 — Three build configurations: Debug, Measure, Release
`CLAUDE.md` allows gating the tooling by `#if DEBUG` *or a build config*, and `#if DEBUG` alone is the wrong
half of the choice: measuring TTFF or peak memory against an unoptimized binary produces numbers that
describe the build settings rather than the design under test. But a plain Release build has no HUD and no
debug menu, so it cannot be driven through a run protocol. "Debug tooling" and "representative performance"
are independent axes, so there are three configurations — `Debug` (tools, unoptimized), `Measure` (tools,
optimized, and **the only configuration a published number may come from**), `Release` (no tools,
optimized). Gating is on `FEEDLAB_TOOLS`, not `DEBUG`. Verified by symbol count: the debug menu is present
in `Measure` and entirely absent from `Release`. The debug menu displays the active configuration and an
`Optimized: No` warning, so measuring the wrong build has to be a deliberate act rather than an oversight.

## 2026-08-01 — Preparation is two-tiered; pool capacity must cover the prepared set
Resolves the question `playback-engine.md` deferred. Asset loading and `AVPlayerItem` construction need no
player, but an item does not **buffer** until associated with an `AVPlayer` — so real preload costs a pool
slot, and `poolCapacity ≥ |itemsToPrepare|` for a strategy to achieve it. Overflow degrades to a playerless
warm (asset loaded, no buffering) rather than being dropped, so an under-provisioned arm produces a
measurable difference instead of a silent one. The existing arm table already satisfies the rule. Flagged
for empirical confirmation in M2 rather than taken as settled.

## 2026-08-01 — A separate planner arbitrates strategy against capacity
`PreloadStrategy` stays pure and capacity-unaware, because that is what makes its index math testable
without a pool. `PreparationPlanner` — also pure — resolves the strategy's ideal set against the actual
capacity and assigns tiers. Keeping arbitration out of both the strategy and the pool means
`playerWaitDuration` measures genuine contention rather than a strategy asking for more than the pool could
ever supply; conflating those two would make a configuration error look like a performance finding.

## 2026-08-01 — XcodeGen `project.yml` as source of truth, generated `.xcodeproj` committed
Build settings in a `pbxproj` are unreviewable: a one-line deployment-target change arrives as a diff of
generated UUIDs. In a repo whose stated goal is legibility that is the wrong default, so targets, settings,
schemes, and the Info.plist are declared in a ~70-line `project.yml`. The generated `.xcodeproj` is
committed anyway so the README's "clone and open, no setup" promise survives — the cost is two artifacts
that can drift, and the rule is: **edit `project.yml`, then `xcodegen generate`, never edit the project in
Xcode's inspector.**

## 2026-08-01 — Swift Testing rather than XCTest
Supersedes the XCTest reference previously in `testing.md`. The required coverage is overwhelmingly
table-shaped — each preload strategy against many index positions, each metric against many synthetic event
sequences — and `@Test(arguments:)` states those tables directly, where XCTest forces either a loop that
reports one failure for the whole table or one method per case. `#expect(throws:)` against an `Equatable`
error also lets validation tests assert *which* rule fired, not merely that something threw.

## 2026-08-01 — Info.plist written explicitly, not generated
`GENERATE_INFOPLIST_FILE` emits a scene manifest with an empty `UISceneConfigurations`, which is right for
a SwiftUI-lifecycle app and silently wrong for a UIKit `AppDelegate`/`SceneDelegate` one: with no
`UISceneDelegateClassName`, UIKit never instantiates the scene delegate, no window is created, and the app
launches to a black screen with no error. Cost us a debugging cycle in M1. The wiring is load-bearing, so
it is declared in `project.yml`'s `info:` block rather than inferred.

## 2026-08-01 — Manifest validation rejects non-HTTPS urls
Not a licensing rule but an adjacent one. A single `http://` entry would require an App Transport Security
exception, and ATS exceptions are granted app-wide rather than per-item — one convenient test stream would
weaken every request the app makes. The validator refuses the trade rather than leaving it to a reviewer to
notice. All approved sources serve HTTPS, so the rule costs nothing today.

## 2026-08-01 — Stream format derived from the URL, not declared in the manifest
A declared `"format": "hls"` field can disagree with reality; the URL cannot. This matters because ABR
metrics (`indicatedBitrate`, bitrate-switch count) are meaningless for progressive files — those access-log
fields stay flat by nature, not by merit — so aggregates must be able to exclude them. A misdeclared field
would corrupt exactly the comparison the rig exists to make.

## 2026-08-01 — No AI-attribution trailers on commits
Claude Code appends a `Co-Authored-By: Claude` trailer to commits and a "Generated with Claude Code" footer to PRs by default. Disabled here via `.claude/settings.json` (`attribution: { commit: "", pr: "" }` — the older `includeCoAuthoredBy: false` boolean is deprecated), with a backstop instruction in `CLAUDE.md`. Rationale: commit authorship should reflect the accountable human author, and the repo's AI-assisted workflow is already documented openly in the README and knowledge base — it doesn't need to be asserted per-commit. Note the setting only affects commits made after it's applied.

## 2026-08-01 — AVPlayerLayer in custom cells, not AVPlayerViewController
`AVPlayerViewController` is the right production choice for a standard player screen and was what I used previously in a healthcare app. It's the wrong choice here: it owns its own controls, lifecycle, and view hierarchy, which hides exactly the layer-attachment, pooling, and first-frame timing behavior this project exists to study. `AVPlayerLayer` in a custom cell keeps that surface visible and measurable.

## 2026-08-01 — Bounded player pool decoupled from cell reuse
Cells recycle on scroll geometry; players must recycle on playback intent. Coupling them (one player per cell, lifecycle tied to `prepareForReuse`) is the naive approach and produces unbounded live players during fast scroll. A separate bounded pool makes capacity an explicit, measurable variable. `pool-unbounded` exists as a deliberate negative-control arm to demonstrate the cost.

## 2026-08-01 — UIKit for the feed surface, SwiftUI for dashboard and HUD
SwiftUI can build this feed natively as of iOS 17: `ScrollView` + `LazyVStack` with `.scrollTargetBehavior(.paging)` and `.containerRelativeFrame(.vertical)`, plus iOS 18's `onScrollVisibilityChange(threshold:)` for current-item detection and `onScrollPhaseChange` for scroll-velocity signals. For a product app targeting iOS 17+ it would be a reasonable default.

UIKit is chosen here for reasons specific to this being a measurement rig:
1. **Lifecycle timing precision** — `willDisplay` / `didEndDisplaying` / `prepareForReuse` fire at explicit, known moments. SwiftUI's `onAppear`/`onDisappear` are advisory; view creation, retention, and discard are framework implementation details that vary across OS versions. TTFF attribution in milliseconds needs the former.
2. **`UICollectionViewDataSourcePrefetching`** — explicit prefetch *and cancel* signals map directly onto `PreloadStrategy`. SwiftUI has no equivalent; prefetch intent would have to be derived from scroll position by hand.
3. **Deterministic reuse** — bounded resource pooling is the subject of the experiment; UIKit's reuse pool is explicit and inspectable, `LazyVStack`'s discard behavior is not contractually specified.
4. **AVPlayerLayer requires a UIKit wrapper regardless** — SwiftUI's `VideoPlayer` is AVKit's `AVPlayerViewController`, which is rejected (see above). A `UIViewRepresentable` is needed either way.

SwiftUI is used where none of that applies: the Swift Charts dashboard and the HUD overlay. Possible stretch experiment: a second SwiftUI feed surface behind the same coordinator protocol, with the rendering layer itself as an experiment arm — does the surface measurably affect TTFF or dropped frames? See `build-plan.md` stretch list.

## 2026-08-01 — Manual arm selection, not randomized assignment
This is a single-operator measurement rig, not an online experiment. Randomization at n=1 user adds variance without validity. The harness is *structured* like an online experiment (named arms, per-arm records, aggregate comparison) so the methodology transfers, and the README states the limitation explicitly rather than implying a real A/B test.

## 2026-08-01 — Metrics layer forbidden from importing AVFoundation
Metric computation is a pure fold over typed `PlaybackEvent`s with injected timestamps. This is what makes the interesting logic unit-testable without a device or a live stream, and it keeps stall/TTFF definitions honest — they're specified in code that can be exercised against synthetic edge cases.

## 2026-08-01 — Seek-to-zero looping rather than AVPlayerLooper
`AVPlayerLooper` requires `AVQueuePlayer` and adds queue semantics that complicate pooling and teardown. Observing `AVPlayerItemDidPlayToEndTime` and seeking to zero is sufficient for a feed, keeps the pool simple, and leaves the item's access log continuous (a fresh looper item would fragment it).

## 2026-08-01 — Numbers only from physical devices
Simulator decode and memory behavior do not represent device behavior. Publishing simulator numbers would make the whole rig untrustworthy. All README figures come from device runs under a stated network profile, with run count and spread reported.

## 2026-08-01 — No video files in the repo; licensed streams only
Manifest of URLs to Apple/Mux test streams, Blender open movies (CC BY, attribution required), and NASA public-domain footage. No platform-sourced content under any circumstances — see `content-sources.md`.
