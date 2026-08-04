---
type: architecture
title: FeedLab Architecture
description: Layers, module boundaries, threading model, state, and project structure
status: living
tags: [architecture, structure, threading]
timestamp: 2026-08-04T00:35:00Z
related: [playback-engine.md, qoe-metrics.md, observability.md, testing.md]
---

# Architecture

## Layers

```
Feed UI (UICollectionView paging, FeedCell owning AVPlayerLayer)
        │
FeedCoordinator — visibility → playback intent; asks pool for players
        │
PlaybackEngine ── PlayerPool (bounded, recycled)
                └ PreloadStrategy (from active experiment arm)
        │
Instrumentation — PlaybackObserver emits typed events
        │
Metrics (pure) — MetricsEngine folds events → PlaybackRecord/SessionSummary
        │
Storage & Presentation — session store, dashboard (SwiftUI/Charts), export
```

The rule that makes this testable: **AVFoundation exists only in PlaybackEngine and Instrumentation.** Everything below consumes typed `PlaybackEvent` values. See `testing.md`.

## Key boundaries

- **`PlayerProviding` / `PlayerItemProviding`** — thin protocols over `AVPlayer`/`AVPlayerItem` exposing only what the engine uses (rate, timeControlStatus, replaceCurrentItem, accessLog/errorLog snapshots, buffer config). Real implementations wrap AVFoundation; fakes drive tests.
- **`PreloadStrategy`** — protocol answering *"given the current index, which items should be prepared, and with what buffer configuration?"* Implementations are pure and unit-tested. See `playback-engine.md`.
- **`PlaybackEvent`** — the instrumentation vocabulary: `.itemBecameCurrent`, `.readyForDisplay`, `.playbackStarted`, `.stallBegan`, `.stallEnded`, `.userPaused`, `.userResumed`, `.accessLogEntry`, `.errorLogEntry`, `.itemEnded`, `.itemReleased`, `.playerWaitBegan/Ended`, each with a monotonic timestamp. Defined in `Metrics/` rather than `Instrumentation/` so it sits inside the region the purity test guards — see `decisions.md`.
- **`MetricsEngine`** — pure fold over `[PlaybackEvent]` → `PlaybackRecord`. No clocks, no AVFoundation, no I/O: injected timestamps only.

## Patterns, and what each one buys

Named here because the shapes are deliberate, and because a reader should be able to tell which are load-bearing
and which are incidental. Each is chosen to serve measurability, not for its own sake.

| Pattern | Where | What it buys |
|---|---|---|
| **Functional core, imperative shell** | AVFoundation confined to PlaybackEngine + Instrumentation; everything below consumes typed events | The rule the whole design serves. Stall and TTFF definitions become code that runs against synthetic edge cases with no device, no network, no video. |
| **Strategy** | `PreloadStrategy` + 4 implementations | Makes preload depth a *value* the experiment varies, rather than a branch in the engine. Swapping an arm swaps an object. |
| **Object pool** | `PlayerPooling` / `PlayerPool` | The subject of the experiment. Unusual property: exhaustion **waits** and the wait is recorded as `playerWaitDuration` rather than hidden — the cost of a too-small pool has to surface somewhere. |
| **Ports and adapters** | `PlayerProviding` / `PlayerItemProviding` | Lets pool logic and metric computation be exercised by fakes. Without it, testing "does release detach observers" needs a real player and a real stream. |
| **Fold over an event log** | `MetricsEngine`: `[PlaybackEvent] → PlaybackRecord` | Events are the source of truth; records are derived projections. Recomputing a metric after a definition change is a re-fold, not a re-run — and a disputed number can be traced to the events that produced it. |
| **Observer, normalised** | `PlaybackObserver` over KVO + `NotificationCenter` | AVFoundation reports through several mechanisms on unspecified queues. Collapsing them into one typed vocabulary on one queue is what makes the fold above possible. |
| **Coordinator** | `FeedCoordinator` (visibility → playback intent) | The seam where a second feed surface plugs in (see the SwiftUI-arm stretch item in `build-plan.md`). |
| **Reconciliation loop** | `FeedCoordinator.reconcile()` against a `PreparationPlan` | Preparation is asynchronous and the scroll does not wait for it. Re-deriving the whole (≤4 index) plan after every completed step means the engine converges from any intermediate state, instead of carrying a correct-transition-per-event burden that fast scroll would eventually violate. |
| **Registry** | `ArmRegistry` | The set under test is legible in one file. |
| **Policy object** | `PreparationPlanner` | Resolves strategy intent against pool capacity without either side knowing the other. See `playback-engine.md`. |
| **DTO** | `ManifestDTO` / `ItemDTO` | Wire format kept separate from the domain model so "field absent" becomes a validation error we phrase, not a `DecodingError`. |

**What is deliberately absent.** No app-wide presentation architecture (MVVM/VIPER/TCA) and no Combine —
both reasoned out in `decisions.md`. Short version: the hard state here is domain state, not view state, and
`MetricsEngine` already *is* a reducer, so the testability those frameworks sell is present without them.
Event delivery stays explicit because the observation surface is the thing being studied. Small
`@Observable` types are used at the three SwiftUI surfaces that genuinely hold view state.

**Two reuse pools, deliberately decoupled.** The one structural idea worth explaining to a reader:
`UICollectionView` recycles cells on *scroll geometry*, while `PlayerPool` recycles players on *playback
intent*. These are different triggers on different clocks, and coupling them — the naive one-player-per-cell
design tied to `prepareForReuse` — is what produces unbounded live players during fast scroll. Keeping them
separate is why pool capacity can be an experiment variable at all.

## Threading

- Main thread: collection view layout, cell binding, `AVPlayerLayer` attachment, HUD updates.
- Off-main: `AVURLAsset` loading (`load(.isPlayable, .duration)`), item preparation, teardown, metric folding, persistence.
- KVO/notification callbacks from AVFoundation arrive on unspecified queues. **Stamp the event with a monotonic timestamp synchronously inside the callback**, then hand it off — delivery is asynchronous (an `AsyncStream<PlaybackEvent>` consumed on a single serial context), but the number is already fixed by then, so scheduling latency cannot leak into a metric. See the measurement-discipline section of `qoe-metrics.md`. Hop to main only for UI.
- Rule: **no asset or item work on the main thread**, ever. Scroll smoothness is a measured output; blocking the main thread invalidates the whole rig.

## State

- `FeedStore` — items from the manifest, current index.
- `SessionStore` — completed sessions, persisted to disk (JSON via Codable, no database needed).
  **One file per session**, not one file holding an array: a session is immutable once sealed, and a
  truncated or unreadable file then costs one session rather than the whole study. `load()` skips
  what it cannot decode and reports how many, because refusing to show any arm because one file is
  corrupt turns a small loss into a total one.
  Each file stores the `SessionSummary` **and the raw `PlaybackEvent`s it was folded from** — the
  persistence half of `SessionRecorder`'s reason for archiving events. Records are a projection; the
  events are the source of truth, so a metric definition can change and be re-derived against runs
  already performed instead of the device runs being repeated. A test asserts the invariant across
  the boundary: re-folding persisted events reproduces the persisted records.
  A session is sealed on arm change and on entering background — the two moments a session really
  ends. Teardown happens *before* sealing, or the item still on screen has emitted no
  `.itemReleased`, has no record, and is silently missing from every run.
- `SettingsStore` — HUD/signpost toggles, selected manifest.

## Data model (sketch)

```swift
struct FeedItem { let id: String; let url: URL; let title: String; let source: ContentSource }

struct PlaybackRecord {            // one per item view
  let itemID: String
  let arm: String
  var timeToFirstFrame: TimeInterval?      // nil = never rendered, NOT zero
  var mediaStackStartupTime: TimeInterval? // access log's own view; the delta from ours is the point
  var stallCount: Int
  var totalStallDuration: TimeInterval
  var watchDuration: TimeInterval          // intent → release, minus user pauses, including stalls
  var observedBitrate: Double?
  var indicatedBitrate: Double?
  var bitrateSwitchCount: Int?             // nil = no ladder (progressive), NOT zero switches
  var droppedFrames: Int?
  var playerWaitDuration: TimeInterval     // blocked time only; instantiation is not contention
  var errors: [PlaybackErrorEvent]
  var rebufferRatio: Double { watchDuration > 0 ? totalStallDuration / watchDuration : 0 }
  var isSkipped: Bool { watchDuration <= 0 }
}

struct SessionSummary { let arm: String; let records: [PlaybackRecord]; let peakMemoryBytes: UInt64; let startedAt: Date; let endedAt: Date }
```

## Project structure

```
project.yml        XcodeGen source of truth; regenerate with `xcodegen generate`
FeedLab/
  App/             AppDelegate, SceneDelegate, RootFactory, Info.plist
  Feed/            FeedViewController, FeedCell, FeedCoordinator, layout
  Playback/        PlaybackEngine, PlayerPool, PreloadStrategy + implementations, protocol wrappers
  Instrumentation/ PlaybackObserver, SignpostEmitter, MemorySampler, TimestampSource, Log
  Metrics/          PlaybackEvent, MetricsEngine, PlaybackRecord, SessionSummary  (pure, no AVFoundation — enforced by test)
  Experiments/     Arm, ArmRegistry, SessionStore
  Dashboard/       SwiftUI views, Swift Charts, export
  Content/         manifest loading, ContentSource + attribution
    manifests/     short-form.json, long-form.json, mixed.json
  Debug/           DebugMenuView, CreditsView, BuildInfo, HUD  (gated on FEEDLAB_TOOLS)
FeedLabTests/      unit tests (metrics, pool, strategies, arm assignment)
docs/              OKF knowledge base
```

Folders not yet populated hold a `.gitkeep`, excluded from the target's sources so they cannot end up as
bundle resources.

### Content layer (M1)

`Content/` depends only on Foundation — no AVFoundation, no UIKit. `ManifestLoader` splits into a pure
`load(from: Data)` that holds all validation logic and a thin `load(resource:in:)` that only locates bytes,
which is what makes the licensing rules testable without a bundle or a device. Decoding uses private DTOs
with every field optional so that "absent" becomes a `ManifestValidationError` we phrase, rather than a
`DecodingError` thrown before we can attribute it to a rule.

`FeedItem.streamFormat` is derived from the URL rather than declared, and `Manifest.hlsItems` exposes the
subset over which ABR metrics are valid — see `content-sources.md` for why that subset is smaller than the
corpus.
