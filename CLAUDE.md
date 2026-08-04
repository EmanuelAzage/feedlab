# CLAUDE.md — FeedLab

A vertical, full-screen paging video feed for iOS built as a **measurement rig**: a bounded pool of recycled `AVPlayer`s, swappable preload strategies behind an experiment harness, and a QoE instrumentation layer that reports time-to-first-frame, rebuffer ratio, bitrate behavior, and peak memory — live in a HUD and afterward in an in-app dashboard.

Native Swift + UIKit (`UICollectionView` compositional layout, paging) with SwiftUI/Swift Charts for the dashboard. The playback engine (player pool + preload strategies) and the QoE layer are the architectural centerpieces. This is **not** a social app clone: no accounts, no backend, no likes/comments. The point is measured playback behavior.

## Knowledge base

`docs/` is the source of truth, an Open Knowledge Format (OKF v0.1) bundle — spec: https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md. Concepts are markdown with YAML frontmatter: `type` (required, lowercase), plus `title`, `description`, `tags`, `timestamp` (ISO-8601), and producer extensions `status` and `related`. Reserved files carry no frontmatter: `index.md` (root index holds only `okf_version`; body is sections of `* [Title](link) - description` bullets) and `log.md` (`## YYYY-MM-DD` headings, bullets led by **Update**/**Creation**/**Decision**).

Start at `docs/index.md` and follow links to the concept relevant to the task. Update the relevant doc in the same change when behavior or decisions change (refresh its `timestamp`); record notable events in `docs/log.md`, newest first.

| Concept | Contents |
|---|---|
| `docs/index.md` | Bundle entry point — read first |
| `docs/product-spec.md` | Screens, feed behavior, HUD, debug menu, UX rules |
| `docs/architecture.md` | Layers, module boundaries, state, project structure |
| `docs/playback-engine.md` | Player pool + preload strategies — the centerpiece spec |
| `docs/qoe-metrics.md` | Metric definitions and exactly how each is measured from AVFoundation |
| `docs/experiment-harness.md` | Arms, assignment, session recording, comparison methodology |
| `docs/observability.md` | HUD, dashboard, export, signposts, screenshot plan |
| `docs/content-sources.md` | Licensed test streams and required attribution |
| `docs/testing.md` | Test strategy and what must stay unit-testable |
| `docs/build-plan.md` | Milestones M1–M6 with acceptance criteria |
| `docs/decisions.md` | Tech choices and why (ADR-lite) |
| `docs/ios-learning-notes.md` | AVFoundation/playback internals (living doc) |
| `docs/log.md` | Chronological history of notable events |

## Project goals (priority order)

1. **Learning depth.** The developer is a senior iOS engineer with strong performance/memory background but no feed-scale playback experience. Prefer the explicit, lower-level solution over the convenience wrapper when it teaches more. When an AVFoundation or playback concept comes up, explain it briefly and append a note to `docs/ios-learning-notes.md`.
2. **Measured claims.** Every performance statement in the README must trace to a number this rig produced. No estimated or remembered figures.
3. **A clean public portfolio repo.** Small, readable, documented, tested. No dead code or TODO litter.

## Commands

```bash
xcodegen generate    # after ANY edit to project.yml — never edit the project in Xcode's inspector
xcodebuild -scheme FeedLab -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme FeedLab -destination 'platform=iOS Simulator,name=iPhone 17' test
swiftlint
```

The destination must name a simulator that exists on the current Xcode's newest runtime — Xcode 26.3 ships
iOS 26.2 sims, which have no "iPhone 16"; `xcrun simctl list devices available` shows what is there.

Measurement runs happen **on a real device** (see `docs/testing.md`) — the simulator misreports video memory and decode performance. The scroll script is code, not a hand gesture: the `FeedLabRunner` UI-test scheme drives one run per invocation.

```bash
TEST_RUNNER_FEEDLAB_ARM=preload1 TEST_RUNNER_FEEDLAB_DWELL=5 \
TEST_RUNNER_FEEDLAB_FORWARD=20 TEST_RUNNER_FEEDLAB_BACK=5 \
xcodebuild test -scheme FeedLabRunner -configuration Measure -destination 'platform=iOS,id=<ECID>'
```

`TEST_RUNNER_*` must be **environment variables of `xcodebuild`**, not trailing build-setting arguments —
as a build setting they are silently dropped and the run starts with no arm. Set Auto-Lock to Never first;
a locked device fails the launch with `FBSOpenApplicationErrorDomain error 7`, which does not mention locking.

### Driving the simulator UI (`idb`)

`xcrun simctl` cannot tap or swipe; `idb` can. Two things cost a cycle each, so they are written down:

- **Switches need a drag, not a tap.** `idb ui tap` on a SwiftUI `Toggle` reports success and changes
  nothing — the row accepts the tap, the control does not. Drag across it instead:
  `idb ui swipe <udid> 336 528 378 528 --duration 0.3`. Pickers can need the same treatment.
- **Read the accessibility tree rather than guessing coordinates.** `idb ui describe-all` returns JSON
  (a list, not one object per line) with each element's `AXLabel`, `AXValue`, and `frame` in *points*.
  It is also how to confirm a control actually changed: check `AXValue` went `0` → `1` rather than
  inferring it from a screenshot, where a toggle's on and off states are nearly indistinguishable at
  screenshot scale.

App logs need `--level debug`, or `Logger.debug`/`.info` lines never appear:
`xcrun simctl spawn <udid> log stream --level debug --predicate 'subsystem == "dev.emanuelazage.FeedLab"'`

## Conventions

- Swift 6, iOS 17+ deployment target. UIKit for the feed surface; SwiftUI + Swift Charts for the dashboard.
- Feed cells own an `AVPlayerLayer`, never an `AVPlayerViewController`.
- All AVFoundation access goes through protocol-wrapped types (`PlayerProviding`, `PlayerItemProviding`) so metric computation and pool logic stay unit-testable without real playback.
- Metric computation is **pure functions over recorded events** — no AVFoundation types in the computation layer.
- No force-unwraps outside tests. No `print`; use the logging/signpost facility.
- Conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `perf:`, `chore:`), one logical change each.
- **No AI-attribution trailers in commits or PRs** — no `Co-Authored-By: Claude`, no `Claude-Session:`, no "Generated with Claude Code" footer. This is a clean public portfolio repo; commit authorship is the human author only. (`.claude/settings.json` enforces this via the `attribution` setting; this line is the backstop if that config is missing or overridden.)

## Guardrails

- **Only licensed streams.** Use the sources in `docs/content-sources.md` (Apple HLS test streams, Mux public test assets, Blender open movies, NASA public domain) with attribution. Never pull video from Reddit, YouTube, TikTok, Instagram, or any platform — copyright and ToS. Never commit video files to the repo; reference URLs in a manifest.
- **Don't use `AVPlayerViewController`** for feed cells; building on `AVPlayerLayer` is the point.
- **Don't let the player pool grow unbounded** as a shortcut — bounded reuse is the core problem being studied. An unbounded mode may exist only as a deliberate experiment arm.
- **Don't invent numbers.** If a metric hasn't been measured on device yet, leave the README table cell empty rather than estimating.
- **Keep the debug HUD out of release builds** (`#if DEBUG` or a build config), but keep it screenshot-able.
