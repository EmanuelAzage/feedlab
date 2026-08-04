---
type: spec
title: FeedLab Product Spec
description: Feed behavior, screens, HUD, debug menu, and UX rules for the playback measurement rig
status: living
tags: [spec, ux, feed, hud]
timestamp: 2026-08-04T01:05:00Z
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
- Select active **experiment arm** (see `experiment-harness.md`), which resets the session. *(M5.)*
  The picker shows the arm's **strategy and pool capacity alongside its name**, because an arm is all
  three — a name-only picker would let the operator select `preload3-capped` without noticing that it
  also moves pool capacity from 3 to 4, and then attribute the difference to preload depth alone.
  The hypothesis is shown too, so the reason an arm exists is legible at the moment it is chosen.
- Toggle HUD *(M4)*, toggle signpost emission *(M6)*.
- Start/stop/reset a measurement session; export results.
- Pick content manifest (short-form clips vs. long-form HLS).

Changes apply on **Done**, not on selection: switching arms tears the session down and rebuilds the
pool, and doing that while the operator is still scrolling the picker would reset the session several
times over.

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

### Portrait only, deliberately

The app is locked to portrait. Two reasons, and the second is the one that decides it:

1. It is the feed convention this app emulates.
2. **Rotation is a measurement confound.** It resizes the `AVPlayerLayer` and forces a relayout of the
   collection view mid-playback, while `testing.md`'s run protocol requires conditions held identical
   across arms. Supporting landscape would mean either controlling for orientation in every run or
   accepting an uncontrolled variable in the comparison.

Worth noting the tension: the corpus is landscape 16:9, so landscape would actually display it better —
which is what `videoGravity = .resizeAspect` addresses instead (`decisions.md`). If the corpus ever gains
portrait-native content this is worth revisiting, but not before.
