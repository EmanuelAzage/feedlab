---
type: reference
title: QoE Metrics — Definitions and Measurement
description: What each quality-of-experience metric means and exactly how FeedLab measures it from AVFoundation
status: living
tags: [qoe, metrics, avfoundation, measurement]
timestamp: 2026-08-04T00:35:00Z
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

**A stall only counts after playback has begun.** `AVPlayer` enters exactly the state above while
filling its buffer *before the first frame*, so the condition as stated is satisfied by every item's
startup. Counting that would report startup twice — once as time-to-first-frame, again as a rebuffer —
and inflate every rebuffer ratio by a roughly constant amount. A constant bias is worse than a random
one: it survives averaging, moves every arm the same way, and looks like a real finding.

Observed in M3 before the guard existed: **every item reported exactly one stall**, of 0.4–0.65 s. With
the rule corrected, clean playback of the same items reports zero. The engine therefore ignores any
`stallBegan` preceding the first `playbackStarted` for that item view.

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

**Measured as:** elapsed time spent *blocked* on an exhausted pool, and nothing else. An acquire that
returns without blocking reports **exactly zero**, including when it had to instantiate a player first.

That exclusion is deliberate and was a real bug during M2. Instantiating an `AVPlayer` costs measurable time
(~5 ms on simulator), and an early implementation reported it as wait. Counting it would have penalised
`pool-unbounded`, which instantiates on nearly every acquire — the arm whose entire purpose is to look
*good* on startup and bad on memory. The metric would have quietly contradicted the finding it exists to
support. Instantiation cost is a property of the player, not of contention; if it is ever worth reporting it
gets its own name.

### Peak resident memory
Sampled during a session via `task_vm_info` and validated against Instruments on device. Attributed to the arm, not to individual items.

**Measured as:** `phys_footprint`, at 5 Hz, running whether or not the HUD is visible — a session metric
must not depend on whether anyone was watching it. `phys_footprint` rather than `resident_size` because it
is what Instruments shows in its Memory column and what jetsam uses to decide what to kill, so it is both
the number a reader recognises and the number that actually constrains the app; `resident_size` counts
shared and file-backed pages the process did not really cost.

**Report it as "peak observed", not "peak."** Sampling cannot see a spike that begins and ends between two
samples, so the figure is a **lower bound** on true peak. Faster sampling narrows the window without ever
closing it. Any README figure must carry the sampling rate, or it claims a precision it does not have.

## Measurement discipline: when the clock is read

A definition, not an implementation detail — every interval above is only as good as the moment its
endpoints were stamped.

**The rule: read the clock at the callback site, before any hop.** A `PlaybackEvent` carries the timestamp
taken synchronously inside the KVO or notification callback that observed the change. Delivery to the
engine — queue hop, `AsyncStream` yield, actor hop — happens *after* stamping, and may therefore be
asynchronous without affecting the number.

Getting this backwards is the failure mode that quietly invalidates a rig: if the timestamp is taken where
the event is *consumed*, every metric silently includes scheduling latency and jitter from the delivery
mechanism. TTFF is a millisecond measurement, and the resulting bias would vary with system load — which is
exactly the variable the experiment is trying to hold still. It would also make arms look different for
reasons that have nothing to do with preload strategy.

Two consequences:

- Use a **monotonic** clock (`ContinuousClock` / `mach_absolute_time`-backed), never wall-clock time. Wall
  clock can step backwards via NTP mid-session, which would produce negative intervals.
- The event vocabulary is timestamp-carrying by construction: `MetricsEngine` never reads a clock, so a
  recorded session re-folds to identical numbers no matter when it is recomputed. This is what makes a
  metric definition change re-derivable rather than requiring a re-run.

## Aggregation rules

- Per item: one `PlaybackRecord`.
- Per session: mean and **p90** TTFF (p90 matters more than mean — startup latency is long-tailed), aggregate rebuffer ratio (total stall ÷ total watch, not the mean of per-item ratios), total stalls, mean switch count, peak memory.
- Items with zero watch duration (scrolled past instantly) are excluded from ratio aggregates but counted in a `skipped` tally — a strategy that looks great because the user never lingered is not actually great.

## What preload does and does not enter into a record

A record covers one **item view**: from playback intent to teardown. Preload happens before intent
exists, so a preloaded item is deliberately **not observed** — `PlaybackObserver` is installed when
the item is promoted to current, not when a player adopts it. A stall suffered while buffering
off-screen is not one the user experienced, and folding it in would put time nobody sat through into
the numerator of rebuffer ratio.

One asymmetry falls out of this and must be read carefully rather than engineered away:

- **Our TTFF is honest under preload.** `t0` is stamped at settle, before anything is consulted, so a
  preloaded item is fast because it really is ready — not because the clock started late.
- **`mediaStackStartupTime` is not.** The access log is *cumulative on the item*, so when observation
  begins at promotion it already contains entries from the preload period. For a preloaded item the
  media stack's startup figure therefore describes work done before the user arrived.

That is arguably the point — the delta between the two is exactly what preload *moves* — but it means
the two startup figures are not comparable across arms in the same way. Bitrate switch counts carry
the same caveat: switches during preload are included. State this wherever the pair is charted.

## Sources of truth and their quirks

- `AVPlayerItem.accessLog()` returns a snapshot; `AVPlayerItemNewAccessLogEntry` notifies on new entries. Entries can be appended for reasons other than a stall (server address change, playlist reload) — always diff against the previous entry rather than assuming one entry per event.
- `errorLog()` captures non-fatal streaming errors that never surface as playback failures. Worth recording: a stream that recovers silently still degraded the experience.
- The **simulator does not represent real decode or memory behavior.** All numbers published in the README come from a physical device (see `testing.md`).
