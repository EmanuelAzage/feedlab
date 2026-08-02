---
type: module-spec
title: Playback Engine — Player Pool and Preload Strategies
description: Bounded AVPlayer pooling, item lifecycle, and the swappable preload strategies the experiments compare
status: living
tags: [avfoundation, player-pool, preload, performance]
timestamp: 2026-08-02T21:38:53Z
related: [architecture.md, qoe-metrics.md, experiment-harness.md]
---

# Playback Engine

The architectural centerpiece. Two problems: **how many players exist and how they're recycled**, and **how far ahead items are prepared**.

## Why pooling at all

`AVPlayer` and its decode pipeline are expensive — memory, decoder sessions, and CPU. One player per visible cell in a paging feed means live instances accumulate as fast as the user scrolls, and hardware decode sessions are a finite resource. Production feeds keep a small number of players and recycle them, decoupled from `UICollectionView`'s cell reuse (cells recycle on scroll geometry; players must recycle on *playback intent*, which is not the same thing).

## PlayerPool

```swift
enum PoolCapacity: Equatable, Sendable { case bounded(Int), unbounded }

struct PooledPlayer: Sendable {
  let player: any PlayerProviding
  let waitDuration: TimeInterval          // 0 when one was free
}

protocol PlayerPooling: Sendable {
  var capacity: PoolCapacity { get }
  func acquire() async throws -> PooledPlayer   // waits if none free; wait is measured
  func release(_ pooled: PooledPlayer) async
}
```

Implemented as an `actor` — the pool *is* the serial context that owns the free list. It also exposes
`occupancy`, `pendingAcquireCount` (callers currently blocked — non-zero means real contention, and it
feeds the HUD), `freeCount`, and `drain()` for tearing down idle players without lowering capacity.

`acquire()` **throws**, unlike the original sketch: a blocked acquire must be cancellable, or a fast scroll
past a waiting item strands a continuation forever. Cancellation resumes it with `CancellationError`.

Rules:
- Fixed `capacity` (default 3: current, next, previous). Capacity is an experiment variable.
- `acquire()` never allocates beyond capacity. If all players are in use, the caller waits and the wait is recorded as `playerWaitDuration` — a first-class metric, because a pool that's too small shows up as startup latency.
- Waiters are served **FIFO**, and a released player is handed straight to the longest-waiting caller rather than round-tripping through the free list, so a queued acquire cannot be overtaken by a fresh one.
- `release()` performs full teardown before the player becomes visible to anyone else. Responsibility splits three ways, and all three must happen or the recycling is unsafe:

  | Step | Owner | Why there |
  |---|---|---|
  | `pause()`, `replaceCurrentItem(nil)`, restore buffer configuration | the pool, via `PlayerProviding.reset()` | the pool is the only thing that knows a player is going back on the shelf |
  | `layer.player = nil` | the cell, on the main actor, *before* releasing | layer work is main-thread-only, and detaching late is what puts a frame of the wrong video in the wrong cell |
  | remove KVO observations and notification tokens | the instrumentation layer, before releasing | it registered them; only it knows what they were |

- **Leak discipline:** every observer registered on acquire must be torn down on release. A leaked KVO observation on a recycled player is the classic bug here and will silently corrupt metrics for later items.

### Layer attachment
`FeedCell` owns a persistent `AVPlayerLayer`; the pool hands over a player and the cell sets `layer.player`. On release, set `layer.player = nil` **before** the player is reused elsewhere to avoid a frame of the wrong video appearing in the wrong cell (a visible, screenshot-able bug worth documenting in the learning notes if it shows up).

## Item lifecycle

1. **Prepare** (off-main): construct `AVURLAsset`, `await asset.load(.isPlayable, .duration)`, build `AVPlayerItem`, apply the arm's buffer configuration, register observers.
2. **Attach**: acquire player from pool, `replaceCurrentItem`, attach to the cell's layer.
3. **Play**: on becoming current. Mark `t0` for time-to-first-frame at the moment playback intent begins (see `qoe-metrics.md` for the precise definition).
4. **Pause/keep warm**: item scrolled just off-screen but still within the strategy's retention window.
5. **Tear down**: outside the window — cancel any in-flight asset loading, release the player, drop the item.

Cancellation matters: a fast scroll must cancel preparation for items the user has already passed, or the rig spends its bandwidth and CPU on videos nobody will see. Structured concurrency tasks per item, cancelled on teardown.

## PreloadStrategy

```swift
protocol PreloadStrategy {
  var name: String { get }
  /// Which item indices to have prepared, given the current index and item count.
  func itemsToPrepare(currentIndex: Int, totalCount: Int) -> [Int]
  /// Buffer configuration applied to each prepared item.
  func bufferConfiguration(for offset: Int) -> BufferConfiguration
}

struct BufferConfiguration {
  var preferredForwardBufferDuration: TimeInterval  // 0 = system default
  var automaticallyWaitsToMinimizeStalling: Bool
  var preferredPeakBitRate: Double                  // 0 = unlimited
}
```

Implementations (these are the experiment arms — see `experiment-harness.md`):

| Strategy | Prepares | Buffer config | Hypothesis |
|---|---|---|---|
| `NoPreload` | current only | system defaults | Baseline. Worst TTFF, least bandwidth. |
| `PreloadNext1` | current, next | default forward buffer | Big TTFF win for the common forward scroll. |
| `PreloadNext3Capped` | current + next 3 | forward buffer capped (e.g. 2–4s), peak bitrate capped on non-current | Better TTFF on fast scroll; risks memory and wasted bytes. |
| `PreloadWindow` | previous 1 + next 2 | default | Handles back-scroll; costs a pool slot. |

Strategies are **pure and unit-tested** — index math and configuration only, no AVFoundation. That keeps the interesting logic verifiable without a device.

## Preparation has two tiers

The question this doc previously deferred — *can an item be prepared without holding a player?* — has a
split answer, and the split determines whether the arm table is even coherent.

| Step | Needs a player? |
|---|---|
| `AVURLAsset` construction | No |
| `await asset.load(.isPlayable, .duration)` — playlist fetch, DNS/TLS warm | No |
| `AVPlayerItem` construction | No |
| **Filling the buffer** (`loadedTimeRanges` growing, `status` leaving `.unknown`) | **Yes** |

An `AVPlayerItem` does not buffer, and its `status` stays `.unknown`, until it is associated with an
`AVPlayer` via `replaceCurrentItem`. So preparation is two tiers:

- **Tier 1 — playerless warm.** Asset loaded, item constructed. Costs a network round trip for the master
  playlist and no decode resources. Fully cancellable. Available to any number of items.
- **Tier 2 — player-backed.** Item attached to a pooled player and buffering under the arm's
  `BufferConfiguration`. This is what actually moves TTFF, and it consumes a pool slot.

**Consequence:** a strategy achieves genuine preload only for items it can put in tier 2, so
`poolCapacity ≥ |itemsToPrepare|`. Checked against the arm table in `experiment-harness.md`, this already
holds — `PreloadNext3Capped` prepares 4 at capacity 4, `PreloadWindow` prepares 4 at capacity 4, and the two
one-and-two-item strategies sit at capacity 3 with a spare slot for the release-then-acquire overlap during
fast scroll. The table was consistent by intuition; it is now consistent by rule.

### Verified 2026-08-02

Measured directly rather than taken from the documentation (macOS, Apple BipBop multi-variant stream; see
`ios-learning-notes.md` for the method):

| State | `status` | Buffered |
|---|---|---|
| Item constructed, never attached, after 8 s | `unknown` | 0.00 s |
| Attached to a player, **never played**, after 3 s | `readyToPlay` | 359 s |
| Attached to a player, **never played**, after 6 s | `readyToPlay` | 908 s, `isPlaybackBufferFull` |

Three consequences:

1. **The two-tier model holds.** An unattached item does not buffer, so `poolCapacity ≥ |itemsToPrepare|`
   stands and the arm table stays coherent.
2. **`play()` is not required to buffer** — attachment alone starts it. This is the mechanism tier 2 uses:
   a preloaded item is attached to a pooled player and left paused. Preload does *not* mean playing muted
   off-screen, which would burn decode resources for nothing.
3. **The system default forward buffer is very large.** Nearly a thousand seconds of content, buffered to
   `isPlaybackBufferFull`, from a single paused item. Across a four-player pool that is a memory problem —
   which promotes `preferredForwardBufferDuration` capping from a tuning knob to the thing that makes deep
   preload viable at all, and sharpens the `PreloadNext3Capped` hypothesis from "should contain the memory
   cost" to "must, or the arm is unusable."

Caveat: run on macOS. (1) and (2) are API contract and carry over. The buffer *magnitude* in (3) is
memory-dependent and must be re-measured on device before any number derived from it is published.

## Arbitrating strategy against capacity

`PreloadStrategy` answers *what would be ideal*; it does not know the pool's capacity, and it should not —
keeping it pure is what makes the index math unit-testable. A separate pure type resolves the two:

```swift
struct PreparationPlan: Equatable {
  let playerBacked: [Int]   // tier 2, in priority order; count ≤ capacity
  let warmOnly: [Int]       // tier 1 overflow
}

enum PreparationPlanner {
  static func plan(currentIndex: Int, totalCount: Int,
                   strategy: PreloadStrategy, capacity: Int) -> PreparationPlan
}
```

Priority order: the current item always first, then by ascending `|offset|`, forward before backward on a
tie (forward scroll dominates a feed). The first `capacity` entries get tier 2; the rest fall back to tier 1
rather than being dropped, so an under-provisioned arm degrades measurably instead of silently.

This keeps `playerWaitDuration` meaningful. With the planner in place, the current item waiting for a player
means genuine contention — a release still in flight during fast scroll — rather than a strategy that asked
for more than the pool could ever supply. Those are different findings and should not share a number.

## Known hazards to watch for

- `preferredForwardBufferDuration` too small causes stalls; too large wastes memory. This tradeoff is exactly what the rig measures.
- Looping via `AVPlayerLooper` requires `AVQueuePlayer`; simple seek-to-zero on `AVPlayerItemDidPlayToEndTime` is sufficient here and keeps pooling simpler. Note the choice in `decisions.md`.
