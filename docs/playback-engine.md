---
type: module-spec
title: Playback Engine — Player Pool and Preload Strategies
description: Bounded AVPlayer pooling, item lifecycle, and the swappable preload strategies the experiments compare
status: living
tags: [avfoundation, player-pool, preload, performance]
timestamp: 2026-08-01T00:00:00Z
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

## Known hazards to watch for

- Preparing more items than the pool has capacity for: preparation and player acquisition are separate resources; an item can be *prepared* without holding a player, but only if the design keeps `AVPlayerItem` construction independent of player attachment. Verify this holds; document it if it doesn't.
- `preferredForwardBufferDuration` too small causes stalls; too large wastes memory. This tradeoff is exactly what the rig measures.
- Looping via `AVPlayerLooper` requires `AVQueuePlayer`; simple seek-to-zero on `AVPlayerItemDidPlayToEndTime` is sufficient here and keeps pooling simpler. Note the choice in `decisions.md`.
