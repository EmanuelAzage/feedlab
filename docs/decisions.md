---
type: decision-log
title: FeedLab Decisions
description: ADR-lite log of technical choices and their rationale
status: living
tags: [decisions, adr, dependencies]
timestamp: 2026-08-05T00:00:00Z
related: [architecture.md, playback-engine.md]
---

# Decisions

Add a dated entry for every non-obvious choice. Newest first.

## 2026-08-04 — Screenshots are captured by a UI test, and looking at them is a test
`ScreenshotRun` drives the device and captures the README images as XCTest attachments. Two reasons
beyond reproducibility: the HUD renders live session figures, so a simulator capture would put
simulator numbers in the README; and a hand-taken screenshot silently goes stale when a chart
changes shape.

It immediately earned itself. Two defects were visible in the output and invisible to 127 passing
tests: the startup-vs-smoothness scatter's point labels collided into an unreadable smear whenever
arms clustered — which is what happens whenever a strategy *works* — and the peak-memory chart drew
nothing at all, because `map(Double.init)` over `[UInt64]` resolves to `Double.init(bitPattern:)`
rather than the numeric conversion, turning 16 MB into 7.9e-317.

The memory bug is the instructive one. It produced **zero-height bars beside a correctly labelled
axis**, which reads as "this arm used no memory" — a plausible claim in a project that had just
reported memory as undifferentiated across arms. It could have been screenshotted, published, and
believed. Nothing caught it because no test asserted `medianPeakMemoryBytes`; the field had a
computation, a chart, and a table, and no assertion anywhere. Two tests now cover it, one through the
aggregation and one across `Codable`, since the dashboard reads sessions from disk.

Published numbers were unaffected — the README's memory figures come from `Scripts/results_table.py`
over the raw JSON, and the HUD reads the sampler directly — which is itself an argument for the
generated-table rule: the bug lived on the *display* path, and the publication path never touched it.

## 2026-08-04 — The scroll script is an XCUITest target, not a hand gesture
The run protocol requires an identical script across arms and originally accepted human timing as
"approximate". It is not approximate enough: a hand-driven run measured 8 s median dwell against a
3 s target, and dwell is watch duration — the *denominator* of aggregate rebuffer ratio. An operator
tiring across an 18-run batch drifts in exactly the shape of an arm effect, and nothing in the data
would distinguish the two.

`FeedLabRunner` takes arm, dwell and swipe counts as environment variables, so one built runner
serves every cell of the matrix, and the protocol becomes reproducible by anyone with the repo
rather than a description of what the author did. It lives on its own scheme: a device run is three
minutes, and `xcodebuild -scheme FeedLab test` has to stay a fast unit run.

Accepted costs, stated in `experiment-harness.md` rather than hidden: XCUITest enables accessibility
in the app process and read ~1.9 MB higher peak footprint, making runner and hand-driven memory
figures separate populations; and the runner flicks at `.fast` velocity rather than using the default
interpolated drag, whose duration would otherwise sit inside the transition being measured.

## 2026-08-04 — The measurement corpus is HLS-only, and the run laps it
Supersedes the "26 item views" entry below, which did not survive contact with the data.

Two attempts to get a usable percentile out of a 22-item corpus failed for the same reason. The
comparison is reported over HLS (see the frozen-frame entry), the manifest holds **7** HLS items, and
nearest-rank p90 over 7 samples is the maximum. Lengthening the script to 20 forward + 5 back did not
help, and the reasoning behind it was simply wrong: the turnaround sits at index 20 and the return
leg ends at 15, so the run never re-enters the HLS block at indices 0–6. HLS coverage stayed at 7.

The corpus is now a separate manifest, `hls-only.json` — the same 7 items, same URLs, same
attributions, asserted by test to be a strict subset of the full one — and the run **laps** it:
6 forward, 6 back, twice. 25 views, all HLS, 22 with a first frame, so p90 is the 20th of 22.

What this costs, and why it is still the right trade:

- **Full-corpus figures are no longer produced per run**, which relaxes the "report both" obligation
  in the frozen-frame entry. The obligation existed so a reader could see that progressive items were
  excluded and why; that is now discharged by the README stating the exclusion and citing the
  measured 27%, rather than by carrying a confounded column beside every result. The metric stays
  implemented and the full manifest remains the app's default — the exclusion is a property of the
  *measurement*, not a quiet narrowing of the app.
- **Later laps run warm.** The first lap is cold, the rest benefit from a warm CDN and OS cache. This
  compresses arm differences — equally for every arm, so the ranking holds, but the magnitudes are a
  floor on what a cold audience would see rather than an estimate of it. Stated with the numbers.

The alternative, three passes over the full 22-item corpus, would have produced the same 21 HLS views
inside a 64-view run — three times the device time to collect the same headline sample, most of it
spent measuring the asset format the comparison excludes.

## 2026-08-04 — The run is 26 item views, because 7 is not enough for a percentile
The comparison is reported over the HLS subset (see the 2026-08-03 entry below), but the manifest
holds 7 HLS items. Nearest-rank p90 over 7 samples *is* the maximum, so the "p90" moved 706→4559 ms
across three runs of one arm while the median moved 24 ms — a one-sample statistic wearing a
percentile's name. Lengthening the script to 20 forward + 5 back gives 26 views per run and roughly
doubles HLS coverage through repeat views on the way back.

The alternative — keep short runs and headline the median — was rejected because p90 is the headline
startup figure precisely for being tail-sensitive (`qoe-metrics.md`), and swapping to the median to
make a small sample behave is choosing the statistic that flatters the data. The cost is re-running
the two arms already measured; those runs keep their original purpose (M4's memory question) and are
preserved in `measurements/` labelled as a separate population.

## 2026-08-03 — The frozen-frame finding is recorded, not fixed; HLS is what this rig is about
27% of progressive MP4 item views never reach playback (`qoe-metrics.md`). The obvious response is to
chase it — larger initial buffers for progressive assets, a different readiness signal, per-format
tuning. **We are not doing that**, and the reason is scope rather than difficulty.

This project studies **bounded player pooling and preload strategy for adaptive streaming**. HLS is
where preload depth, buffer caps and the bitrate ladder are meaningful levers; a progressive MP4 has
no ladder, no segments, and — as measured — no access-log telemetry at all. Fixing progressive
startup would be a real improvement to the *app* and would teach almost nothing about the *question*.

Three consequences, all of which have to be honoured or the finding becomes an excuse:

- **The metric stays.** `isFrozen` is implemented and reported. Declining to fix a failure is only
  defensible while it remains visible; the fix that must never happen is deleting the measurement.
- **Arm comparisons are reported over the HLS subset**, with the full-corpus figures alongside. Nine
  frozen item views spread unevenly across runs would otherwise move p90 TTFF by more than any
  preload strategy does, so a whole-corpus comparison would be measuring asset format while
  appearing to measure strategy. `Manifest.hlsItems` already exists for the ABR metrics; the same
  boundary now applies to the headline pair.
  **Revised 2026-08-04** — the "alongside" half is dropped: runs are now against an HLS-only corpus,
  so there are no full-corpus figures to carry. The purpose it served, handing the reader the
  exclusion rather than letting them infer it, moves to the README. See the entry above.
- **The README says so.** "7 of 22 items are HLS, and the comparison is over those" is a limitation
  a reader must be handed, not one they should have to infer from a corpus table.

Revisit if the corpus ever becomes HLS-dominant, which `content-sources.md` explains is unlikely —
licensable HLS is scarce, and that scarcity is why the corpus is progressive-heavy in the first
place.

## 2026-08-03 — Only the current item may block on the pool
Preload needs a player only if one is going spare, and `acquire()` is the wrong tool for it. Waiters are
served FIFO, so a queued preload acquire sits *ahead* of the acquire for whichever item the user scrolls to
next: the item they are actually waiting on would wait behind speculative work for one they may never reach.
`acquireIfAvailable()` returns nil instead, leaving the item at tier 1 — a degradation the rig can see rather
than a latency it cannot.

The bug this prevents would have been **self-concealing**: preload delaying the current item surfaces as
worse time-to-first-frame *on the preload arms*, which reads as a clean result ("preloading didn't help")
rather than as a defect in the rig. Same category as the startup-counted-as-a-stall correction below.

## 2026-08-03 — Preloaded items are not observed
`PlaybackObserver` is installed on promotion to current, not when a player adopts the item. A record covers
one *item view*, from intent to teardown; a stall suffered while buffering off-screen is not one the user
experienced, and folding it in would put time nobody sat through into the numerator of rebuffer ratio.

The asymmetry this creates is documented rather than engineered away: our TTFF stays honest under preload
because `t0` is stamped at settle, but the **access log is cumulative on the item**, so a preloaded item's
`mediaStackStartupTime` and switch count still include preload activity. The delta between the two startup
figures is exactly what preload moves, which makes it interesting — but it means they are not comparable
across arms in the same way. See `qoe-metrics.md`.

## 2026-08-03 — Cell visibility stops playback; the plan decides player retention
`cellDidEndDisplaying` demotes rather than tears down. This restates the M2 correction rather than reversing
it. The bug then was a departed item continuing to *play* and to accrue watch duration; full teardown was
the remedy chosen, and it was equivalent only because nothing else could hold a player. Preload breaks that
equivalence — an item legitimately holds a player while off-screen — so the two concerns separate.

## 2026-08-03 — Reconciliation re-derives the plan instead of patching state
Preparation is asynchronous and the scroll does not wait for it, so a per-event transition table would have
to be correct for every interleaving a fast scroll can produce. `reconcile()` re-derives the whole plan after
every completed step, converging from any intermediate state. Affordable because a plan is at most four
indices — the cost is bounded by the thing being measured.

## 2026-08-03 — Sessions persist as one file each, carrying their raw events
One file per session rather than one file holding an array: a session is immutable once sealed, and a
truncated file then costs one session rather than the whole study. Re-running an arm on a device is the
expensive thing here, so `load()` skips what it cannot decode and reports how many rather than failing the
read.

Each file stores the summary **and the events it was folded from**, which is the persistence half of
`SessionRecorder`'s reason for archiving them: records are a projection, events are the source of truth, so a
metric definition can change and be re-derived against runs already performed. A test asserts the invariant
across the boundary.

Sealing required a `drain()` barrier on the event pipe — events reach the recorder through an `AsyncStream`,
so reading the summary straight after teardown raced the drain and would have dropped every run's final item
view. The barrier is a marker yielded into the same stream, relying on the ordering guarantee the pipe
already exists to provide.

## 2026-08-02 — Startup buffering is not a stall
`AVPlayer` enters `.waitingToPlayAtSpecifiedRate` with reason `.toMinimizeStalls` while filling its buffer
*before the first frame*, which satisfies the stall condition in `qoe-metrics.md` exactly as written. Taken
literally it made **every item report exactly one stall** of 0.4–0.65 s — startup counted twice, once as
time-to-first-frame and again as a rebuffer. A constant bias like that is more dangerous than a noisy one:
it survives averaging, shifts every arm identically, and reads as a genuine result. The engine now ignores
any `stallBegan` preceding the first `playbackStarted` for that item view, and clean playback of the same
streams reports zero.

The fix also exposed under-specified tests: several fixtures omitted `.playbackStarted` and had been passing
because the rule was too permissive. Real event streams always contain it before a genuine rebuffer.

## 2026-08-02 — Events are delivered through an ordered `AsyncStream`, not a task per event
The obvious `Task { await recorder.record(event) }` per callback spawns unordered tasks: an event stamped
before `.itemReleased` can arrive after it, land in a fresh bucket, and never be folded. Timestamps would
still be right and the record would still be wrong. `PlaybackEventPipe` wraps an unbounded `AsyncStream`
whose `yield` is thread-safe and order-preserving, drained by one detached consumer — the single serial
context `architecture.md` calls for. Buffering is unbounded deliberately: dropping events under load would
corrupt records at exactly the moments worth measuring.

## 2026-08-02 — `PlaybackEvent` lives in `Metrics/`, not `Instrumentation/`
`architecture.md` originally placed the event vocabulary under `Instrumentation/`. Moved, because this type
*is* the boundary: if an `AVPlayerItem` ever appears on it the whole no-AVFoundation guarantee collapses
silently. FeedLab is a single module, so the rule cannot be enforced by the compiler — it is enforced by a
test that scans the `Metrics/` directory, and the vocabulary belongs inside the region that test covers.
`Instrumentation/` produces events; `Metrics/` owns the contract and consumes them.

## 2026-08-02 — Optional means "not applicable", never "zero"
`bitrateSwitchCount`, `droppedFrames` and the bitrates are optional on `PlaybackRecord`, and aggregates skip
nil rather than substituting zero. A progressive MP4 has no ladder, so reporting zero switches for it would
read as a flawless ABR result on a stream where the question is meaningless — and it would dilute the mean
for the HLS items that *can* switch. Since our corpus is 7 HLS to 15 progressive (`content-sources.md`),
that dilution would have been the dominant effect rather than a rounding detail. The nil cases fall out of
the event stream naturally: no access-log entry ever carried an indicated bitrate, so there is nothing to
count.

## 2026-08-02 — p90 is nearest-rank, and the method is named
Percentile methods disagree, and the README quotes these numbers, so "p90" alone is not a specification.
Nearest-rank always returns an actually-observed value; linear interpolation at the small n of a single run
can land between two real samples and report a startup time that never occurred. Stated on `Percentile`
itself so the definition travels with the code.

## 2026-08-02 — Gestures assigned to M3 because user-pause is a metrics requirement
`product-spec.md` has specified tap-to-pause, double-tap-to-seek and long-press-for-source since the start,
but no milestone ever claimed them. They belong in M3 rather than a UI milestone because `qoe-metrics.md`
requires excluding user-initiated pauses from **both** the numerator and denominator of rebuffer ratio —
so `.userPaused`/`.userResumed` must exist in the vocabulary for the metric to be correct, gesture or no
gesture. The events are implemented and tested ahead of the UI that will emit them.

## 2026-08-02 — `videoGravity = .resizeAspect`, not `.resizeAspectFill`
A real short-form feed carries 9:16 content and fills the screen. Our corpus is landscape 16:9 test
streams, and aspect-fill into a 9:19.5 frame crops so hard that most of the frame — including BipBop's
clock, the fastest way to see *which* item is playing and whether it is actually advancing — sits
off-screen. Legibility of the subject under test beats feed cosmetics. Revisit if the corpus ever gains
portrait-native content, at which point this arguably becomes per-item rather than global.

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
