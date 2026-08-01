---
type: module-spec
title: Playback Engine — Player Pool and Preload Strategies
description: Bounded AVPlayer pooling, item lifecycle, and the swappable preload strategies the experiments compare
status: living
tags: [avfoundation, player-pool, preload, performance]
timestamp: 2026-08-01T20:41:00Z
related: [architecture.md, qoe-metrics.md, experiment-harness.md]
---

# Playback Engine

The architectural centerpiece. Two problems: **how many players exist and how they're recycled**, and **how far ahead items are prepared**.

## Why pooling at all

`AVPlayer` and its decode pipeline are expensive — memory, decoder sessions, and CPU. One player per visible cell in a paging feed means live instances accumulate as fast as the user scrolls, and hardware decode sessions are a finite resource. Production feeds keep a small number of players and recycle them, decoupled from `UICollectionView`'s cell reuse (cells recycle on scroll geometry; players must recycle on *playback intent*, which is not the same thing).

## PlayerPool

```swift
protocol PlayerPooling {
  func acquire() async -> PooledPlayer      // waits if none free; wait is measured
  func release(_ player: PooledPlayer)
  var capacity: Int { get }
  var occupancy: Int { get }
}
```

Rules:
- Fixed `capacity` (default 3: current, next, previous). Capacity is an experiment variable.
- `acquire()` never allocates beyond capacity. If all players are in use, the caller waits and the wait is recorded as `playerWaitDuration` — a first-class metric, because a pool that's too small shows up as startup latency.
- `release()` performs full teardown before returning the player: `pause()`, `replaceCurrentItem(with: nil)`, detach from any `AVPlayerLayer`, remove KVO observers and notification tokens, reset `preferredForwardBufferDuration` / `preferredPeakBitRate`.
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

> **Verify in M2.** The tier-2 claim is the documented AVFoundation contract, not something this rig has
> measured. Confirm it directly: construct an `AVPlayerItem`, never attach it, and observe that
> `loadedTimeRanges` stays empty and `status` stays `.unknown`. If that turns out to be wrong, the arm
> capacities and this whole section change — record the finding in `ios-learning-notes.md` either way.

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
