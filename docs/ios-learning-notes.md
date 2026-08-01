---
type: learning-notes
title: iOS Playback Learning Notes
description: Living doc of AVFoundation and feed-playback internals - seeded with topics, filled in with notes as they come up in practice
status: living
tags: [learning, avfoundation, playback, performance]
timestamp: 2026-08-01T19:07:52Z
related: [playback-engine.md, qoe-metrics.md]
---

# iOS Playback Learning Notes

Living doc. When a playback concept surfaces during the build, append a short note: what it is, where it appeared in this codebase, and how it maps to prior experience (native iOS, memory/performance profiling, cross-platform work). Seed topics below.

## The AVFoundation playback object graph
`AVURLAsset` (the media + its metadata) → `AVPlayerItem` (one playback session over an asset: buffers, logs, status) → `AVPlayer` (the transport: rate, timeControlStatus) → `AVPlayerLayer` (the render surface). Knowing which object owns which responsibility is most of the API. Note where each is created and destroyed in `Playback/`.

## Asynchronous asset loading
Modern async `load(.isPlayable, .duration, ...)` replaces the older `loadValuesAsynchronously`. Loading is I/O and must never block the main thread. Note what happens to TTFF when loading is *not* prepared ahead — that difference is the `baseline` arm.

## timeControlStatus vs. rate
`rate` is intent; `timeControlStatus` is reality. `.waitingToPlayAtSpecifiedRate` with `reasonForWaitingToPlay == .toMinimizeStalls` is the authoritative rebuffer signal — more reliable than the stall notification alone. Record which one fires first in practice.

## Buffering knobs
`preferredForwardBufferDuration` (how much to buffer ahead), `automaticallyWaitsToMinimizeStalling` (start fast vs. start safe), `preferredPeakBitRate` (cap the ladder). These are the levers the preload strategies pull; note the measured effect of each rather than the documented one.

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

## Player pooling and decode resources
Why live `AVPlayer` count matters: memory, decode sessions, dropped frames. Note the actual numbers observed at pool sizes 3, 4, and unbounded.

## Prior-experience bridges
- Bounded pooling of expensive resources ↔ prior image-pipeline memory work (peak usage on ~100-image sets, ~4GB → under 700MB). Same shape: cap the live set, recycle, measure.
- Keeping asset I/O off the main thread ↔ prior main-thread-I/O and watchdog-termination debugging.
- `AVAudioSession` category/interruption handling ↔ audio-capture work in the VoiceInk native module (the capture side of the same framework).
- Instruments + signposts ↔ existing profiling practice, now applied to playback rather than list rendering.
