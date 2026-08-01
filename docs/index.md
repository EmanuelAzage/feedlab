---
okf_version: "0.1"
---

# FeedLab Knowledge Base

FeedLab is a vertical full-screen paging video feed for iOS, built as a measurement rig: a bounded pool of recycled `AVPlayer`s, swappable preload strategies behind an experiment harness, and a QoE instrumentation layer reporting time-to-first-frame, rebuffer ratio, bitrate behavior, and peak memory — live in a HUD and afterward in a Swift Charts dashboard. Native Swift/UIKit for the feed, SwiftUI for the dashboard. No accounts, no backend: the point is measured playback behavior.

# Concepts

* [FeedLab Product Spec](product-spec.md) - Feed behavior, screens, HUD, debug menu, and UX rules
* [FeedLab Architecture](architecture.md) - Layers, module boundaries, threading model, state, and project structure
* [Playback Engine](playback-engine.md) - Bounded player pooling, item lifecycle, and swappable preload strategies (centerpiece)
* [QoE Metrics](qoe-metrics.md) - What each metric means and exactly how it is measured from AVFoundation
* [Experiment Harness](experiment-harness.md) - Arms, selection, run protocol, and honest comparison methodology
* [Observability](observability.md) - HUD, Swift Charts dashboard, signposts, export, and the README screenshot plan
* [Content Sources and Licensing](content-sources.md) - Approved test streams and required attribution
* [Testing and Measurement Protocol](testing.md) - Unit test strategy and the protocol for publishable numbers
* [FeedLab Build Plan](build-plan.md) - Milestones M1-M6 with acceptance criteria
* [FeedLab Decisions](decisions.md) - Technical choices and rationale; check before adding dependencies
* [iOS Playback Learning Notes](ios-learning-notes.md) - Living doc of AVFoundation internals; append as concepts arise

# History

* [Update Log](log.md) - Chronological history of notable project events, newest first

# Maintenance rules

* Update the relevant concept doc in the same change that alters behavior or decisions, and refresh its `timestamp`.
* Metric definitions in [qoe-metrics.md](qoe-metrics.md) must match implementation exactly — change both together or neither.
* Never publish a number that did not come from a device run following [the measurement protocol](testing.md).
* Record notable events in [log.md](log.md) under an ISO-dated heading, newest first, with a bold leading convention word (**Update**, **Creation**, **Decision**).
* Frontmatter: `type` is required on every concept; recommended fields are `title`, `description`, `tags`, `timestamp` (ISO-8601); producer extensions in use here are `status` and `related`. Reserved files `index.md` and `log.md` carry no frontmatter (root index carries only `okf_version`).
