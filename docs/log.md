# FeedLab Update Log

## 2026-08-01

* **Initialization**: Created the knowledge base — [product spec](product-spec.md), [architecture](architecture.md), [playback engine](playback-engine.md), [QoE metrics](qoe-metrics.md), [experiment harness](experiment-harness.md), [observability](observability.md), [content sources](content-sources.md), [testing protocol](testing.md), [build plan](build-plan.md) (M1-M6), [decisions](decisions.md), and [learning notes](ios-learning-notes.md).
* **Decision**: Scoped as a playback measurement rig rather than a feed-app clone. Bounded player pool decoupled from cell reuse designated the architectural centerpiece; `AVPlayerLayer` in custom UIKit cells over `AVPlayerViewController`; metrics layer forbidden from importing AVFoundation to keep computation unit-testable; numbers published only from physical-device runs. See [decisions](decisions.md).
