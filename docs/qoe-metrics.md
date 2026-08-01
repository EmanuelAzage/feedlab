---
type: reference
title: QoE Metrics — Definitions and Measurement
description: What each quality-of-experience metric means and exactly how FeedLab measures it from AVFoundation
status: living
tags: [qoe, metrics, avfoundation, measurement]
timestamp: 2026-08-01T00:00:00Z
related: [playback-engine.md, observability.md, experiment-harness.md]
---

# QoE Metrics

The vocabulary streaming teams actually use, plus the precise measurement method in this codebase. **Definitions must match implementation** — if the code changes how something is computed, update this doc in the same change.

## The metrics

### Time to first frame (TTFF) — *startup time*
Interval from playback intent to the first rendered frame. The metric users feel most; in a feed it's the difference between "instant" and "laggy."

**Measured as:** `t0` = the moment the item becomes current and play is requested (not when the cell is created). `t1` = `AVPlayerLayer.isReadyForDisplay` becoming `true` (KVO). TTFF = `t1 − t0`.
Cross-check against `AVPlayerItemAccessLogEvent.startupTime`, which measures the media stack's own view of startup — the two differ (ours includes pool wait and attach; Apple's is network/decode oriented), and **the delta between them is itself interesting** — it isolates app-induced latency from media-stack latency. Record both.

### Rebuffer ratio (stall ratio)
Fraction of intended watch time spent stalled. The single best summary of playback smoothness. Industry framing is that even low single-digit percentages are noticeable.

**Measured as:** `totalStallDuration / watchDuration`. Stall begins when `AVPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate` **and** `reasonForWaitingToPlay == .toMinimizeStalls`; it ends when status returns to `.playing`. Cross-check stall *count* against `AVPlayerItemPlaybackStalled` notifications and `accessLog` `numberOfStalls`. Exclude user-initiated pauses from both numerator and denominator.

### Stall count
Number of rebuffering interruptions. Distinct from ratio: one 4-second stall and eight 0.5-second stalls score the same ratio but feel very different.

### Observed vs. indicated bitrate
`observedBitrate` is the throughput actually achieved; `indicatedBitrate` is the bitrate of the variant currently selected from the HLS ladder. Observed falling below indicated is the precondition for a downswitch.

**Measured as:** latest `AVPlayerItemAccessLogEvent` fields, sampled on `AVPlayerItemNewAccessLogEntry`.

### Bitrate switch count
How often ABR changed variants. High switching is visually distracting even when nothing stalls.

**Measured as:** count of access-log events whose `indicatedBitrate` differs from the previous entry; `switchBitrate` corroborates.

### Dropped frames
`numberOfDroppedVideoFrames` from the access log. Rises when decode or rendering can't keep up — often the first sign that too many players are alive at once.

### Player wait duration *(FeedLab-specific)*
Time an item spent waiting for a free player from the bounded pool. Not a standard streaming metric; it exists because pool capacity is an experiment variable and its cost has to surface somewhere. Folds into TTFF but is recorded separately so the two causes of slow startup — pool contention vs. network/decode — stay distinguishable.

### Peak resident memory
Sampled during a session via `task_vm_info` / `mach_task_basic_info` (resident size), and validated against Instruments on device. Attributed to the arm, not to individual items.

## Aggregation rules

- Per item: one `PlaybackRecord`.
- Per session: mean and **p90** TTFF (p90 matters more than mean — startup latency is long-tailed), aggregate rebuffer ratio (total stall ÷ total watch, not the mean of per-item ratios), total stalls, mean switch count, peak memory.
- Items with zero watch duration (scrolled past instantly) are excluded from ratio aggregates but counted in a `skipped` tally — a strategy that looks great because the user never lingered is not actually great.

## Sources of truth and their quirks

- `AVPlayerItem.accessLog()` returns a snapshot; `AVPlayerItemNewAccessLogEntry` notifies on new entries. Entries can be appended for reasons other than a stall (server address change, playlist reload) — always diff against the previous entry rather than assuming one entry per event.
- `errorLog()` captures non-fatal streaming errors that never surface as playback failures. Worth recording: a stream that recovers silently still degraded the experience.
- The **simulator does not represent real decode or memory behavior.** All numbers published in the README come from a physical device (see `testing.md`).
