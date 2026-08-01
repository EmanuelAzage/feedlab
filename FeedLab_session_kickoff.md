# FeedLab — session kickoff prompt

Paste into a fresh Claude Code session opened at the root of the FeedLab repo (the folder containing `CLAUDE.md`, `README.md`, and `docs/`). Reusable — paste it at the start of every session, not just the first.

---

We're building FeedLab: a vertical full-screen paging video feed for iOS that measures its own playback quality. A bounded pool of recycled `AVPlayer`s, swappable preload strategies behind an experiment harness, and a QoE instrumentation layer (time-to-first-frame, rebuffer ratio, bitrate behavior, peak memory) surfaced in a live HUD and a Swift Charts dashboard.

Before writing any code, read these and confirm you've internalized them:
1. `CLAUDE.md` — working agreement, conventions, guardrails.
2. `docs/index.md` — knowledge-base entry point, then follow its links.
3. `docs/build-plan.md` — milestones M1–M6 with acceptance criteria.
4. `docs/playback-engine.md` — player pool and preload strategies (the centerpiece).
5. `docs/qoe-metrics.md` — metric definitions and exactly how each is measured.
6. `docs/decisions.md` — why the design is what it is.

Then tell me: the current state of the repo (what exists, what the log says was last done), which milestone we're on and which acceptance criteria remain, and your proposed plan for this session. **Wait for my confirmation before editing.**

## How I want to work

**This is a learning project first, a portfolio repo second.** I'm a senior iOS engineer with deep Swift, architecture, and memory/performance-profiling experience, but feed-scale video playback is new to me. So:

- **Teach as you build.** When we hit an AVFoundation or playback concept I may not know deeply — the asset/item/player/layer object graph, `timeControlStatus` vs `rate`, buffering knobs, HLS variant switching, access/error logs, decode resource limits — explain it briefly as we use it. Relate it to what I already know: bounded-resource pooling (I've done image-pipeline memory work taking peak usage on ~100-image sets from ~4GB to under 700MB), keeping I/O off the main thread, Instruments profiling, and `AVAudioSession` work from the capture side. Don't over-explain Swift, UIKit, concurrency, or architecture patterns.
- **Append what we learn to `docs/ios-learning-notes.md`** as we go — what it is, where it appeared in our code, and the bridge to prior experience. Match the depth of the existing notes.
- **Explain your choices.** When you pick an approach, say why in a sentence. Non-obvious calls get an entry in `docs/decisions.md`.
- **I review everything.** Propose diffs and explain them. Small, reviewable commits (conventional-commit style, one logical change each).
- **Sessions are short and irregular.** Always leave the repo compiling with tests passing, the docs updated, and `docs/log.md` current, so the next session can resume cleanly. If we're mid-milestone when I stop, say exactly what's left.

## Guardrails (restated from CLAUDE.md because they matter)

- **Don't use `AVPlayerViewController`** for feed cells — `AVPlayerLayer` in custom cells is the point.
- **Don't let the player pool grow unbounded** as a shortcut. Bounded reuse is the subject of the experiment; the unbounded mode exists only as the deliberate negative-control arm.
- **`Metrics/` must never import AVFoundation.** Metric computation is a pure fold over typed `PlaybackEvent`s with injected timestamps, so it stays unit-testable without a device.
- **Never invent numbers.** No estimated or remembered figures anywhere — README cells stay empty until measured on a physical device following `docs/testing.md`. Simulator numbers are never published.
- **Licensed streams only** (Apple/Mux test streams, Blender open movies with attribution, NASA public domain). Never platform-sourced video. No video files committed.
- **Maintain the knowledge base as we work:** update the relevant doc *and* its `timestamp` in the same change; record notable events in `docs/log.md`; keep the bundle OKF-conformant. If metric definitions change, `docs/qoe-metrics.md` and the implementation change together.

## This session's goal

Continue at the current milestone per `docs/build-plan.md` and drive toward its acceptance criteria, teaching the playback-specific parts as we go. Then we'll commit and update the log together.

Start by reading the docs and reporting back the repo state and your plan. Don't edit yet.
