---
type: spec
title: Testing and Measurement Protocol
description: Unit test strategy, what must remain testable without a device, and the protocol for producing publishable numbers
status: living
tags: [testing, measurement, protocol]
timestamp: 2026-08-04T17:30:00Z
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

- **The `Measure` configuration.** Optimized (`-O`) with the tooling compiled in — see `decisions.md`. A
  `Debug` build is unoptimized and its numbers describe the build settings, not the design; the debug menu
  shows `Optimized: No` precisely so this cannot happen by accident. Never publish a number from `Debug`.
- **Physical device**, stated by model and iOS version in the README. The simulator misrepresents decode, memory, and thermal behavior — never publish simulator numbers.
- **Network conditions** set with Network Link Conditioner; each arm run under at least unthrottled Wi-Fi and one constrained profile. State the profile with every number.
- **Identical run script** across arms — 20 items forward, 5 back, 5 s dwell, driven by the
  `FeedLabRunner` UI test target rather than by hand, because human dwell varied by more than 2x and
  dwell is the denominator of rebuffer ratio. Invocation and caveats in `experiment-harness.md`.
- **≥3 runs per arm per profile**, arms alternated rather than run consecutively; report the median
  and the observed spread.
- **Cold start** before each arm; discard and note the warm-up item.
- Export via CSV; the README table is generated from the export, never hand-typed.

## Practical notes for device sessions

Learned the hard way; each of these cost a cycle.

- **Profiling needs a USB cable.** Install, launch and debug all work fine over Wi-Fi, but
  `xctrace record` against a wirelessly-connected device fails with "An unknown problem is preventing
  this device from recording" and silently produces a zero-duration trace **targeting the Mac**. Check the
  exported `--toc`: if `<device>` says `platform="macOS"`, the trace is worthless regardless of what the
  recording reported.
- **Each tool uses a different device identifier.** `devicectl` uses a UUID, `xcodebuild -destination` and
  `xctrace --device` use the ECID (`00008101-…`). `--device-name` is ambiguous when two devices share a
  name, which is common.
- **`xctrace --attach` takes a process name, not a bundle id.** `--launch` takes the bundle id.
- **Do not close the app mid-recording.** `--launch` samples the process it started; backgrounding or
  killing it ends the trace.
- **`xctrace export --xpath` writes to stdout**; redirecting with `2>/dev/null` can silently yield an
  empty file.
- **Symbolication:** system frameworks (AVFCore, CoreMedia, UIKitCore) symbolicate from the device support
  bundle, but an optimized app binary shows raw addresses. That is usually fine — the question "is asset
  work on the main thread" is answered by *framework* symbols, which do resolve.
- **A locked device fails the launch**, with `FBSOpenApplicationErrorDomain error 7` rather than anything
  naming the lock. Set Auto-Lock to Never before an unattended batch; a 50-minute run dies at whichever
  arm the screen happened to sleep on, and that arm is then the one missing runs.
- **Pull sessions with `devicectl device copy from`**, `--domain-type appDataContainer --user mobile`,
  source `Library/Application Support/FeedLab/Sessions`. Reinstalling preserves the container; only
  `devicectl device uninstall` clears it, which is how a batch starts from a clean corpus.

## Running the measurement batch

`FeedLabRunner` is its own scheme deliberately: `xcodebuild -scheme FeedLab test` must stay a fast unit
run, not a three-minute device session. See `experiment-harness.md` for the invocation and for what the
UI-test harness costs the measurement.

## Regression check

Before any release/tag: run the unit suite, then one `baseline` and one `preload1` run on device and confirm the numbers sit within the previously recorded spread. A big unexplained shift means the rig changed, and the README's numbers need re-derivation.
