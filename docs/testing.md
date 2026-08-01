---
type: spec
title: Testing and Measurement Protocol
description: Unit test strategy, what must remain testable without a device, and the protocol for producing publishable numbers
status: living
tags: [testing, measurement, protocol]
timestamp: 2026-08-01T19:07:52Z
related: [architecture.md, experiment-harness.md, qoe-metrics.md]
---

# Testing and Measurement

Two separate things: **unit tests** (does the logic hold?) and **measurement runs** (what are the numbers?). Neither substitutes for the other.

## Unit tests (Swift Testing, no device required)

The suite uses **Swift Testing** (`@Test` / `#expect` / `@Suite`), not XCTest — see `decisions.md`. Most of
the required coverage below is table-shaped (one strategy against many index positions, one metric against
many event sequences), and `@Test(arguments:)` expresses that directly instead of as hand-rolled loops or
one method per case. Tests run on a simulator; none of them require a device or a live stream.

The architecture exists to make the interesting parts testable without playing video. Required coverage:

- **MetricsEngine** — the priority. Feed synthetic `[PlaybackEvent]` sequences with injected timestamps and assert the resulting `PlaybackRecord`. Cases: clean playback; single long stall; many short stalls; user pause excluded from watch duration and stall time; zero-watch item excluded from ratio aggregates; TTFF when `readyForDisplay` precedes/follows play intent; missing `readyForDisplay` (never rendered) yields nil TTFF, not zero.
- **Aggregation** — mean vs. p90 TTFF; aggregate rebuffer ratio computed as total-over-total, *not* the mean of ratios (assert these differ on a crafted case, so the distinction can't silently regress).
- **PreloadStrategy** implementations — pure index math: near the start, near the end, single-item manifest, index out of range, and the exact prepared set for each strategy.
- **PlayerPool** — acquire/release under capacity; acquire when exhausted waits and records wait duration; release resets state and detaches observers; no allocation beyond capacity (assert with a fake player factory that counts instantiations).
- **Manifest validation** — an entry missing `license`/`attribution` fails to load. *(Done, M1.)* Also
  covered: every required field enforced, whitespace-only values treated as absent, duplicate ids rejected,
  non-HTTPS urls rejected, empty item list rejected, malformed JSON surfaced as a manifest error rather than
  a `DecodingError`, and the shipped `short-form.json` asserted valid and ≥20 items.

Fakes live in `FeedLabTests/Fakes/` implementing `PlayerProviding`/`PlayerItemProviding`. No AVFoundation import anywhere in `Metrics/`; add a test that fails if one appears, or enforce by module boundary.

## What is not unit tested

Actual decode behavior, real network stalls, and memory under load. These are measured, not asserted. Don't write brittle integration tests against live streams — network flakiness would make CI meaningless.

## Measurement protocol

Numbers published in the README come only from runs following this protocol:

- **Physical device**, stated by model and iOS version in the README. The simulator misrepresents decode, memory, and thermal behavior — never publish simulator numbers.
- **Network conditions** set with Network Link Conditioner; each arm run under at least unthrottled Wi-Fi and one constrained profile. State the profile with every number.
- **Identical run script** across arms (fixed manifest, item order, and scroll sequence — see `experiment-harness.md`).
- **≥3 runs per arm per profile**; report the median and the observed spread.
- **Cold start** before each arm; discard and note the warm-up item.
- Export via CSV; the README table is generated from the export, never hand-typed.

## Regression check

Before any release/tag: run the unit suite, then one `baseline` and one `preload1` run on device and confirm the numbers sit within the previously recorded spread. A big unexplained shift means the rig changed, and the README's numbers need re-derivation.
