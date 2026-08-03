---
type: learning-notes
title: iOS Playback Learning Notes
description: Living doc of AVFoundation and feed-playback internals - seeded with topics, filled in with notes as they come up in practice
status: living
tags: [learning, avfoundation, playback, performance]
timestamp: 2026-08-03T00:29:26Z
related: [playback-engine.md, qoe-metrics.md]
---

# iOS Playback Learning Notes

Living doc. When a playback concept surfaces during the build, append a short note: what it is, where it appeared in this codebase, and how it maps to prior experience (native iOS, memory/performance profiling, cross-platform work). Seed topics below.

## The AVFoundation playback object graph
`AVURLAsset` (the media + its metadata) → `AVPlayerItem` (one playback session over an asset: buffers, logs, status) → `AVPlayer` (the transport: rate, timeControlStatus) → `AVPlayerLayer` (the render surface). Knowing which object owns which responsibility is most of the API. Note where each is created and destroyed in `Playback/`.

**M2 — the edge that isn't obvious from the diagram: an `AVPlayerItem` is inert until a player adopts it.**
Measured on macOS against Apple's BipBop multi-variant stream (throwaway script; deliberately *not* a
committed test, per `testing.md` — live-stream tests would make CI meaningless):

```
unattached, t=8s          status=unknown      buffered=  0.00s
attached (paused), t=3s   status=readyToPlay  buffered=359.09s  likelyToKeepUp=true
attached (paused), t=6s   status=readyToPlay  buffered=907.81s  bufferFull=true
```

Three things fell out of this, in increasing order of surprise:

1. **No buffering without a player.** The item's `status` never leaves `.unknown` and `loadedTimeRanges`
   stays empty. So "preload" in the sense that matters — bytes on the device — costs a pool slot, which is
   what fixes `poolCapacity ≥ |itemsToPrepare|` in `playback-engine.md`.
2. **`play()` is not required.** Attachment alone starts buffering. Preloading is therefore *attach and
   stay paused*, not "play muted off-screen", which would spend decode resources on frames nobody sees.
3. **The default forward buffer is enormous** — ~908 s buffered, `isPlaybackBufferFull`, from one paused
   item within six seconds. This is the finding that changes a design: four preloaded players at the system
   default is a memory problem, so `preferredForwardBufferDuration` capping is what makes deep preload
   possible rather than merely tidier. (Magnitude is macOS-specific and gets re-measured on device.)

**Bridge to prior experience:** this is the decode-side analogue of the image-pipeline work — the expensive
resource isn't the object you hold (`AVPlayerItem` unattached is nearly free, like an undecoded image
reference), it's the buffer that materialises when you *bind* it. Capping the live set is the same move;
here the cap has two dimensions, how many players and how much each buffers.

**Gotcha found while measuring this:** the first run of the script reported zero buffering even for the
attached item, because it blocked the main thread on a semaphore while waiting. AVFoundation's state
machine needs a live main run loop to progress — replacing the semaphore with `RunLoop.main.run()` made the
numbers appear. A concrete demonstration of the project's own rule: block the main thread and playback does
not merely stutter, it does not proceed at all.

## Asynchronous asset loading
Modern async `load(.isPlayable, .duration, ...)` replaces the older `loadValuesAsynchronously`. Loading is I/O and must never block the main thread. Note what happens to TTFF when loading is *not* prepared ahead — that difference is the `baseline` arm.

## timeControlStatus vs. rate
`rate` is intent; `timeControlStatus` is reality. `.waitingToPlayAtSpecifiedRate` with `reasonForWaitingToPlay == .toMinimizeStalls` is the authoritative rebuffer signal — more reliable than the stall notification alone. Record which one fires first in practice.

## Buffering knobs
`preferredForwardBufferDuration` (how much to buffer ahead), `automaticallyWaitsToMinimizeStalling` (start fast vs. start safe), `preferredPeakBitRate` (cap the ladder). These are the levers the preload strategies pull; note the measured effect of each rather than the documented one.

**M2 — the buffer is resident memory, and the cap has a floor.** Two things measured on macOS with four
attached-but-never-played items (`phys_footprint` delta):

| Case | Buffered | Footprint delta |
|---|---|---|
| 1 item, system default | 907.8 s | +57.9 MB |
| 4 items, system default | 538.5 s | +90.9 MB |
| 4 items, capped 5 s | 39.6 s | +1.5 MB |

First: **buffering is not disk-backed.** I had assumed the "908 s buffered" figure implied a memory problem;
that was an inference from a *duration*, and durations are not bytes — HLS segments could plausibly have
been spooled to disk. They are not, and the lever works: ~60× less footprint growth when capped. Worth
noting the four-item default case buffered *less in total* than the single item, because four concurrent
loads contend for bandwidth — so it was still filling when sampled and +90.9 MB understates steady state.

Second, and the more useful correction: **`preferredForwardBufferDuration` cannot go below one segment.**
Capping at 5 s produced ~10 s per item, because BipBop segments are ~10 s (`#EXT-X-TARGETDURATION:11`,
`#EXTINF:9.9766`). The player cannot hold a fraction of a segment. Our own spec had suggested "e.g. 2–4 s"
for the capped arm, which on this corpus would have been a **no-op** — the arm would have looked like it was
testing a buffer cap while testing only preload depth. Caps belong in segment multiples.

**Bridge to prior experience:** the same class of mistake as assuming a downsampled image costs less
resident memory than its decode buffer — the knob you set and the resource you consume are separated by an
implementation detail (segment size here, decode geometry there), and only measuring finds the floor.

**Method note:** both findings came from throwaway scripts in a scratch directory, deliberately not
committed as tests — `testing.md` forbids CI tests against live streams. What lands in the repo is the
finding and its caveats, not the harness.

## HLS and ABR
Multi-variant playlists, the bitrate ladder, and how the player switches variants under changing throughput. Observed vs. indicated bitrate, and why a downswitch is preceded by observed falling below indicated. Contrast with progressive MP4, which has none of this.

**M1 — what a real ladder looks like.** Read Apple's BipBop master playlist directly while building the
manifest (`curl` the `.m3u8`; a multi-variant playlist is just text, which is worth internalising — the
"ladder" is not an abstraction, it is a list of `#EXT-X-STREAM-INF` lines each pointing at a media playlist):

| Variant | Resolution | BANDWIDTH |
|---|---|---|
| gear0 | audio only | 41 kbps |
| gear1 | 416×234 | 264 kbps |
| gear2 | 640×360 | 578 kbps |
| gear3 | 960×540 | 916 kbps |
| gear4 | 1280×720 | 1.03 Mbps |
| gear5 | 1920×1080 | 1.92 Mbps |

Two things to carry into M3. First, `BANDWIDTH` is the *peak* the variant may hit; the advanced fMP4 stream
also carries `AVERAGE-BANDWIDTH`, and ABR decisions weigh them differently — so `indicatedBitrate` from the
access log will be one of these declared numbers, not something the player measures. `observedBitrate` is
the measured one. Comparing a declared number against a measured number is the whole game. Second, the
audio-only rendition means a "downswitch" can end at *no video at all*, which would look like a stall to a
user but produces no stall event. Worth checking whether that shows up during throttled runs.

**Prior-experience bridge:** this is the same shape as serving responsive images from a size ladder — the
decision of which rung to fetch is made per-segment against measured throughput, rather than once per asset.
The difference is that the video decision is revisited every few seconds under a live bandwidth estimate.

## The public test-stream landscape
Not an API concept, but load-bearing for a rig that can only publish measurements it is licensed to take.
Most tutorial-famous URLs are dead: Blender's own `download.blender.org` 403s programmatic requests, the
Google `gtv-videos-bucket` MP4s 403, Bitmovin's Sintel 403s, and Wikimedia's Big Buck Bunny transcodes are
VP9/WebM, which `AVPlayer` will not decode at all. Separately, *reachable is not licensed*: several
`test-streams.mux.dev` entries serve fine but their underlying content cannot be identified, and one is
broadcast footage. Probe before trusting, and record the finding — see `content-sources.md` for the
verified list and the resulting HLS-vs-progressive split.

**Foundation gotcha found here:** classifying a stream by `URL.pathExtension` misclassifies Unified
Streaming's `…/tears-of-steel.ism/.m3u8`, whose last path component is the dotfile-looking `.m3u8` —
Foundation reports an empty extension. `lastPathComponent.hasSuffix(".m3u8")` is correct. Getting this
wrong would silently drop a real HLS stream out of the ABR aggregates, which is the failure mode where a
bug looks like a result.

## Access log and error log
`accessLog()`/`errorLog()` and their `New...LogEntry` notifications are the media stack's own telemetry — the closest thing to a free QoE feed. Note the quirks discovered in practice (entries appended for non-stall reasons, fields that stay zero on progressive assets).

**M3 — how a bitrate "switch" is actually counted.** `accessLog()` returns a *snapshot* of every entry so
far; `newAccessLogEntryNotification` fires when one is appended. `PlaybackObserver` takes the last entry on
each notification and flattens it into an `AccessLogSnapshot`.

Three fields carry the ABR story, and the first two are the pairing that makes it legible:

| Field | Meaning |
|---|---|
| `indicatedBitrate` | the **declared** bitrate of the variant currently selected — straight from the playlist's `BANDWIDTH` attribute |
| `observedBitrate` | the **measured** throughput actually achieved |
| `switchBitrate` | corroborating signal for a change |

A *switch* is a rung change on the ladder — the player deciding, before fetching the next ~10 s segment,
that a different variant suits current conditions. Observed falling below indicated is the precondition for
a downswitch. Comparing a declared number against a measured one is the whole mechanism.

Counting switches means **diffing `indicatedBitrate` against the previous entry, not counting entries.**
Entries are appended for playlist reloads and server address changes too, so counting entries reports
switches that never happened. There is a test pinning exactly this.

Three traps found in practice:

1. **`-1` means "not available", not zero.** Mapped to nil at the observer, which is where the metrics
   layer's "optional means not applicable, never zero" convention originates rather than being imposed on
   it. A progressive MP4 leaves most of these unpopulated.
2. **`startupTime` is not our TTFF.** It is the media stack's own view — network/decode oriented — where
   ours starts at playback intent and includes pool wait and layer attach. Both are recorded because *the
   delta between them isolates app-induced latency from media-stack latency*, which is the number that
   tells us whether a slow start is our fault or the network's.
3. **The audio-only rung.** A deep enough downswitch lands on gear0, which has no video: frozen frame,
   audio continuing. It feels like a stall to the user but produces no stall event and no dropped frames —
   a degradation invisible to every metric we currently collect. Worth watching for under throttling.

First real observation (simulator, warm cache, three Apple streams under identical conditions): **2, 0 and
3** switches respectively. The variation is the cheap sanity check — a broken implementation (always zero,
or counting every entry) would most likely produce a constant across streams. Weak evidence, but the only
kind available without a controlled network.

**Bridge to prior experience:** `srcset` picks an image size once per viewport; ABR re-decides every
segment against a live bandwidth estimate, mid-playback. Same idea — serve from a ladder — but the decision
is continuous rather than one-shot, which is why it needs telemetry to reason about at all.

## Player pooling and decode resources
Why live `AVPlayer` count matters: memory, decode sessions, dropped frames. Note the actual numbers observed at pool sizes 3, 4, and unbounded.

## Where playback CPU actually goes (first device trace)
36 s Time Profiler on an iPhone 12 Pro under continuous scrolling, one video playing throughout:

- **Total samples in FeedLab: 856.** At 1 ms weighting that is under a second of app CPU across 36 s.
  Decode does not run in our process — `AVFoundation` drives `mediaserverd` out-of-process, so the app pays
  for *coordination*, not for decoding. Worth internalising: a video feed's CPU profile looks nothing like
  an image pipeline's, where the decode is yours.
- **Main thread: 422 samples (~1.2% of wall time), dominated by `UIKitCore`** — i.e. scrolling, which is
  what it should be doing.
- **The only media symbols on main were notification delivery**:
  `CMNotificationCenterPostNotification`, `__avplayeritem_fpItemNotificationCallback_block_invoke`, plus
  single samples of `-[AVPlayerItem isPlaybackBufferEmpty]` and `_loadedTimeRangesFromFPPlaybableTimeIntervals:`.
  ~35 ms total. This is inherent: AVFoundation posts item notifications on the main queue. It is *delivery*,
  not *work*, and it is the category we should expect to remain.
- **Zero hangs** at the 250 ms threshold.

The absence that mattered: no `-[AVURLAsset initWithURL:options:]` and no `-[AVPlayerItem initWithAsset:]`
on main, confirming the `ItemPreparer` fix independently of the debug assert. Note that system frameworks
symbolicate from the device support bundle even when the optimized app binary does not — which is lucky,
because the question is answered entirely by framework symbols.

## AVAudioSession is a measurement variable, not just a UX detail
The default category is `.soloAmbient`: silenced by the ringer switch, and deactivated when the app
backgrounds. A silenced session can mean the audio decode path does no work at all — so the same arm,
measured twice, could exercise a video-only pipeline on a muted device and a full audio+video pipeline
otherwise. That is a variance source with nothing to do with preload strategy. Set explicitly to `.playback`
/ `.moviePlayback` in `AudioSessionConfigurator`.

**Bridge to prior experience:** this is the same object as the capture-side `AVAudioSession` work in
VoiceInk, approached from the other end. There the category governed whether recording could proceed and how
it interacted with other audio; here it governs whether the playback workload is constant across runs. Same
process-wide singleton, same category/mode vocabulary, opposite direction of data flow — and in both cases
the failure mode is silent rather than an error.

## Seeking, and why tolerance matters for a loop
Looping is `seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)` on
`AVPlayerItemDidPlayToEndTime`. The tolerances are not boilerplate: `seek(to:)` without them lets the player
land on the nearest keyframe, which is cheaper but can be up to a GOP away from the true start. In a looping
feed that error accumulates every lap, and **watch duration is the denominator of rebuffer ratio** — so a
sloppy loop would slowly inflate the smoothness score of any item the user lingered on. Exact seeking costs
a little decode work and buys a stable denominator.

## Prior-experience bridges
- Bounded pooling of expensive resources ↔ prior image-pipeline memory work (peak usage on ~100-image sets, ~4GB → under 700MB). Same shape: cap the live set, recycle, measure.
- Keeping asset I/O off the main thread ↔ prior main-thread-I/O and watchdog-termination debugging.
- `AVAudioSession` category/interruption handling ↔ audio-capture work in the VoiceInk native module (the capture side of the same framework).
- Instruments + signposts ↔ existing profiling practice, now applied to playback rather than list rendering.
