---
type: spec
title: FeedLab Product Spec
description: Feed behavior, screens, HUD, debug menu, and UX rules for the playback measurement rig
status: living
tags: [spec, ux, feed, hud]
timestamp: 2026-08-01T00:00:00Z
related: [architecture.md, playback-engine.md, observability.md]
---

# Product Spec

FeedLab is a vertical full-screen video feed whose purpose is to **measure its own playback quality** under different strategies. It looks like a consumer feed; it behaves like an instrument.

## Screens

### Feed (primary)
- Full-screen, vertically paged `UICollectionView`. One video per page, snapping.
- The **current** item plays automatically; all others are paused. Audio follows the current item only.
- Tap toggles play/pause. Double-tap seeks to start. Long-press shows the item's stream/source info.
- Scrubber and elapsed/duration are minimal and non-blocking; this isn't a player UI showcase.
- Looping playback on the current item (feed convention, and it keeps a stalled item observable).

### HUD overlay (debug builds)
Toggleable from the debug menu. Renders live over the feed:
- Current item: time-to-first-frame, stall count, stall duration, rebuffer ratio so far, observed vs. indicated bitrate, dropped frames.
- Session-wide: items viewed, mean TTFF, aggregate rebuffer ratio, current player-pool occupancy, peak resident memory.
- Active experiment arm name, prominently — so a screenshot is self-documenting.

### Dashboard
In-app SwiftUI + Swift Charts view of the completed session(s): see `observability.md` for the chart set. Reachable from the debug menu. Supports export.

### Debug menu
- Select active **experiment arm** (see `experiment-harness.md`), which resets the session.
- Toggle HUD, toggle signpost emission.
- Start/stop/reset a measurement session; export results.
- Pick content manifest (short-form clips vs. long-form HLS).

## Feed behavior rules

- **Playback follows visibility, not existence.** Only the item crossing the "current" threshold plays. Items leaving the screen pause and release their player back to the pool.
- **Preloading is a strategy, never hardcoded.** The number of items prepared ahead and their buffer configuration come from the active arm.
- **The pool is bounded.** If no player is available, the feed does not create one — it waits and records the wait as a metric (`playerWaitDuration`). This is the constraint that makes the experiment meaningful.
- **Degradation is visible, not hidden.** When an item stalls, the HUD shows it and the session records it. No spinner-and-forget.
- **Scroll is never blocked by playback work.** Asset loading, preparation, and teardown happen off the main thread; the main thread does layout and rendering only.

## Session model

A **session** starts when the user begins scrolling under a selected arm and ends when they stop it from the debug menu. It records a per-item `PlaybackRecord` and session-level aggregates. Sessions persist locally so multiple arms can be compared in the dashboard without re-running everything.

## Non-goals

Accounts, backend, likes/comments/sharing, uploads, DRM/FairPlay, offline download, iPad-optimized layout, Picture-in-Picture, AirPlay, captions UI (though caption tracks in test streams should not break playback).
