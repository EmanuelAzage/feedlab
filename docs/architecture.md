---
type: architecture
title: FeedLab Architecture
description: Layers, module boundaries, threading model, state, and project structure
status: living
tags: [architecture, structure, threading]
timestamp: 2026-08-01T19:07:52Z
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
- **`PlaybackEvent`** — the instrumentation vocabulary: `.itemBecameCurrent`, `.readyForDisplay`, `.stallBegan`, `.stallEnded`, `.accessLogEntry`, `.errorLogEntry`, `.itemEnded`, `.itemReleased`, `.playerWaitBegan/Ended`, each with a monotonic timestamp.
- **`MetricsEngine`** — pure fold over `[PlaybackEvent]` → `PlaybackRecord`. No clocks, no AVFoundation, no I/O: injected timestamps only.

## Threading

- Main thread: collection view layout, cell binding, `AVPlayerLayer` attachment, HUD updates.
- Off-main: `AVURLAsset` loading (`load(.isPlayable, .duration)`), item preparation, teardown, metric folding, persistence.
- KVO/notification callbacks from AVFoundation arrive on unspecified queues — normalize immediately onto a dedicated serial queue before mutating engine state, then hop to main only for UI.
- Rule: **no asset or item work on the main thread**, ever. Scroll smoothness is a measured output; blocking the main thread invalidates the whole rig.

## State

- `FeedStore` — items from the manifest, current index.
- `SessionStore` — active arm, in-flight `PlaybackRecord`s, completed `SessionSummary`s, persisted to disk (JSON via Codable, no database needed).
- `SettingsStore` — HUD/signpost toggles, selected manifest.

## Data model (sketch)

```swift
struct FeedItem { let id: String; let url: URL; let title: String; let source: ContentSource }

struct PlaybackRecord {            // one per item view
  let itemID: String
  let arm: String
  var timeToFirstFrame: TimeInterval?
  var stallCount: Int
  var totalStallDuration: TimeInterval
  var watchDuration: TimeInterval
  var observedBitrate: Double?
  var indicatedBitrate: Double?
  var bitrateSwitchCount: Int
  var droppedFrames: Int
  var playerWaitDuration: TimeInterval
  var errors: [PlaybackErrorEvent]
  var rebufferRatio: Double { watchDuration > 0 ? totalStallDuration / watchDuration : 0 }
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
  Instrumentation/ PlaybackObserver, PlaybackEvent, SignpostEmitter, MemorySampler, Log
  Metrics/          MetricsEngine, PlaybackRecord, SessionSummary  (pure, no AVFoundation)
  Experiments/     Arm, ArmRegistry, SessionStore
  Dashboard/       SwiftUI views, Swift Charts, export
  Content/         manifest loading, ContentSource + attribution
    manifests/     short-form.json, long-form.json, mixed.json
  Debug/           DebugMenu, HUD
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
