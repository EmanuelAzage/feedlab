# FeedLab

A vertical, full-screen video feed for iOS that **measures its own playback quality**.

A bounded pool of recycled `AVPlayer`s, swappable preload strategies behind an experiment harness, and a QoE instrumentation layer that reports time-to-first-frame, rebuffer ratio, bitrate behavior, and peak memory — live in a HUD while you scroll, and afterward in a Swift Charts dashboard.

> **Status:** in active development — see [docs/build-plan.md](docs/build-plan.md) for milestone progress.

<!-- M6: hero image — docs/images/dashboard-tradeoff.png (p90 TTFF vs rebuffer ratio, one point per arm) -->

## Why this exists

Playing one video is easy. Playing the *next* video instantly, on a phone, over a bad network, without the memory and decoder cost of a dozen live players, is the actual problem — and it's a problem you can only reason about with numbers. FeedLab is the rig I built to get those numbers.

Two things it's deliberately not: it's not a social app (no accounts, no backend, no likes), and it's not a wrapper around `AVPlayerViewController`. The feed cells own `AVPlayerLayer`s and the pooling is hand-rolled, because that surface is the thing being studied. Design rationale is logged in [docs/decisions.md](docs/decisions.md); what I learned along the way is in [docs/ios-learning-notes.md](docs/ios-learning-notes.md).

## Results

<!-- M6: generate this table from an exported CSV. Do not hand-type numbers. Leave cells empty until measured on device. -->

Device: _TBD_ · iOS _TBD_ · runs per arm: _TBD_ · median of runs.

| Arm | Preload | Pool | p90 TTFF | Rebuffer ratio | Peak memory | Dropped frames |
|---|---|---|---|---|---|---|
| `baseline` | none | 3 | | | | |
| `preload1` | next 1 | 3 | | | | |
| `preload3-capped` | next 3, capped buffers | 4 | | | | |
| `window` | prev 1 + next 2 | 4 | | | | |
| `pool-unbounded` | next 1 | ∞ | | | | |

Measured under two network profiles (unthrottled Wi-Fi and a constrained profile via Network Link Conditioner). Methodology, and its limits, in [docs/experiment-harness.md](docs/experiment-harness.md) — in short: this is a single-operator measurement rig with manually selected arms, not an online A/B test, and it's reported as such.

## How it works

```
Feed UI (UICollectionView paging · FeedCell owns AVPlayerLayer)
        │
FeedCoordinator — visibility → playback intent
        │
PlaybackEngine ── PlayerPool (bounded, recycled)
                └ PreloadStrategy (from the active experiment arm)
        │
Instrumentation — typed PlaybackEvents (KVO, notifications, access/error logs)
        │
Metrics (pure, no AVFoundation) — fold events → PlaybackRecord → SessionSummary
        │
HUD · Swift Charts dashboard · CSV/JSON export · os_signpost
```

The boundary that matters: **AVFoundation lives only in the playback and instrumentation layers.** Metric computation is a pure fold over typed events with injected timestamps, so stall detection, TTFF, and aggregation are unit-tested against synthetic edge cases without a device or a live stream. See [docs/architecture.md](docs/architecture.md) and [docs/testing.md](docs/testing.md).

Metric definitions — what counts as a stall, when the TTFF clock starts, why aggregate rebuffer ratio isn't the mean of per-item ratios — are specified in [docs/qoe-metrics.md](docs/qoe-metrics.md).

## Screenshots

<!-- M6: capture on device, light + dark. Store in docs/images/ -->
<!-- feed.png · hud.png · dashboard-ttff.png · dashboard-memory.png · instruments-signposts.png -->

## Running it

Requirements: Xcode 16+, iOS 17+ device (the simulator misreports decode and memory — see below).

```bash
git clone <repo> && cd FeedLab
open FeedLab.xcodeproj
```

No API keys, no backend, no setup. Video comes from a manifest of public test streams. The project is
generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); the `.xcodeproj` is
committed, so you only need XcodeGen if you change the project structure (`xcodegen generate`).

Three build configurations, because debug tooling and representative performance are independent axes:

| Configuration | Tooling | Optimized | Use |
|---|---|---|---|
| `Debug` | yes | no | development |
| `Measure` | yes | **yes** | measurement runs — the only source of published numbers |
| `Release` | no | yes | the clean app |

Debug menu (shake or the on-screen button) selects the experiment arm, toggles the HUD, and opens the dashboard. It reports the active configuration and warns when the build is unoptimized, so a run against the wrong binary can't happen quietly.

<!-- M6: verify these steps on a clean machine -->

**On the simulator:** the app runs, but any number it produces is meaningless. Decode is software, memory accounting differs, and there's no thermal behavior. All published figures come from a physical device under a stated network profile.

## The knowledge base

`docs/` is an LLM-friendly knowledge base following the [Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md) — markdown concepts with YAML frontmatter, an [index](docs/index.md) for progressive disclosure, and a [log](docs/log.md) of notable events. Coding agents read it before working and update it as behavior changes; humans get the same docs with no translation. `CLAUDE.md` / `AGENTS.md` define the working agreement.

## Content and licensing

FeedLab ships no video. The manifest references publicly available, licensed test content: Apple and Mux HLS test streams, Blender Foundation open movies (CC BY — © Blender Foundation), and NASA public-domain footage. Per-item attribution is required by the manifest schema and shown in-app. Full detail in [docs/content-sources.md](docs/content-sources.md).

## License

MIT (application code). Referenced media remains under its own license as listed above.
