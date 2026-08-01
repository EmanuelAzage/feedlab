---
type: decision-log
title: FeedLab Decisions
description: ADR-lite log of technical choices and their rationale
status: living
tags: [decisions, adr, dependencies]
timestamp: 2026-08-01T00:00:00Z
related: [architecture.md, playback-engine.md]
---

# Decisions

Add a dated entry for every non-obvious choice. Newest first.

## 2026-08-01 — No AI-attribution trailers on commits
Claude Code appends a `Co-Authored-By: Claude` trailer to commits and a "Generated with Claude Code" footer to PRs by default. Disabled here via `.claude/settings.json` (`attribution: { commit: "", pr: "" }` — the older `includeCoAuthoredBy: false` boolean is deprecated), with a backstop instruction in `CLAUDE.md`. Rationale: commit authorship should reflect the accountable human author, and the repo's AI-assisted workflow is already documented openly in the README and knowledge base — it doesn't need to be asserted per-commit. Note the setting only affects commits made after it's applied.

## 2026-08-01 — AVPlayerLayer in custom cells, not AVPlayerViewController
`AVPlayerViewController` is the right production choice for a standard player screen and was what I used previously in a healthcare app. It's the wrong choice here: it owns its own controls, lifecycle, and view hierarchy, which hides exactly the layer-attachment, pooling, and first-frame timing behavior this project exists to study. `AVPlayerLayer` in a custom cell keeps that surface visible and measurable.

## 2026-08-01 — Bounded player pool decoupled from cell reuse
Cells recycle on scroll geometry; players must recycle on playback intent. Coupling them (one player per cell, lifecycle tied to `prepareForReuse`) is the naive approach and produces unbounded live players during fast scroll. A separate bounded pool makes capacity an explicit, measurable variable. `pool-unbounded` exists as a deliberate negative-control arm to demonstrate the cost.

## 2026-08-01 — UIKit for the feed, SwiftUI for the dashboard
`UICollectionView` compositional layout with paging is the production-standard feed surface and gives precise control over cell lifecycle, prefetching, and reuse timing — all measurement-relevant. SwiftUI + Swift Charts is the fastest path to a good-looking dashboard and needs none of that control. Mixed-stack is deliberate, not incidental.

## 2026-08-01 — Manual arm selection, not randomized assignment
This is a single-operator measurement rig, not an online experiment. Randomization at n=1 user adds variance without validity. The harness is *structured* like an online experiment (named arms, per-arm records, aggregate comparison) so the methodology transfers, and the README states the limitation explicitly rather than implying a real A/B test.

## 2026-08-01 — Metrics layer forbidden from importing AVFoundation
Metric computation is a pure fold over typed `PlaybackEvent`s with injected timestamps. This is what makes the interesting logic unit-testable without a device or a live stream, and it keeps stall/TTFF definitions honest — they're specified in code that can be exercised against synthetic edge cases.

## 2026-08-01 — Seek-to-zero looping rather than AVPlayerLooper
`AVPlayerLooper` requires `AVQueuePlayer` and adds queue semantics that complicate pooling and teardown. Observing `AVPlayerItemDidPlayToEndTime` and seeking to zero is sufficient for a feed, keeps the pool simple, and leaves the item's access log continuous (a fresh looper item would fragment it).

## 2026-08-01 — Numbers only from physical devices
Simulator decode and memory behavior do not represent device behavior. Publishing simulator numbers would make the whole rig untrustworthy. All README figures come from device runs under a stated network profile, with run count and spread reported.

## 2026-08-01 — No video files in the repo; licensed streams only
Manifest of URLs to Apple/Mux test streams, Blender open movies (CC BY, attribution required), and NASA public-domain footage. No platform-sourced content under any circumstances — see `content-sources.md`.
