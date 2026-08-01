---
type: learning-notes
title: iOS Playback Learning Notes
description: Living doc of AVFoundation and feed-playback internals - seeded with topics, filled in with notes as they come up in practice
status: living
tags: [learning, avfoundation, playback, performance]
timestamp: 2026-08-01T00:00:00Z
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

## Access log and error log
`accessLog()`/`errorLog()` and their `New...LogEntry` notifications are the media stack's own telemetry — the closest thing to a free QoE feed. Note the quirks discovered in practice (entries appended for non-stall reasons, fields that stay zero on progressive assets).

## Player pooling and decode resources
Why live `AVPlayer` count matters: memory, decode sessions, dropped frames. Note the actual numbers observed at pool sizes 3, 4, and unbounded.

## Prior-experience bridges
- Bounded pooling of expensive resources ↔ prior image-pipeline memory work (peak usage on ~100-image sets, ~4GB → under 700MB). Same shape: cap the live set, recycle, measure.
- Keeping asset I/O off the main thread ↔ prior main-thread-I/O and watchdog-termination debugging.
- `AVAudioSession` category/interruption handling ↔ audio-capture work in the VoiceInk native module (the capture side of the same framework).
- Instruments + signposts ↔ existing profiling practice, now applied to playback rather than list rendering.
