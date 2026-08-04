---
type: spec
title: Experiment Harness
description: How arms are defined, selected, recorded, and compared so playback strategy choices are data-driven
status: living
tags: [experiments, ab-testing, methodology]
timestamp: 2026-08-04T01:05:00Z
related: [playback-engine.md, qoe-metrics.md, observability.md]
---

# Experiment Harness

The rig's reason for existing: make "which preload strategy is better?" an answerable question instead of an opinion.

## Arm

```swift
struct Arm {
  let name: String              // stable identifier, appears in every record and screenshot
  let strategy: PreloadStrategy
  let poolCapacity: Int
  let notes: String             // the hypothesis being tested
}
```

Arms are declared in a single `ArmRegistry` so the set under test is legible in one file.

## Starting set

| Arm | Strategy | Pool | Hypothesis |
|---|---|---|---|
| `baseline` | `NoPreload` | 3 | Control. Establishes worst-case TTFF and lowest memory. |
| `preload1` | `PreloadNext1` | 3 | One-ahead preparation should cut TTFF substantially on forward scroll for modest cost. |
| `preload3-capped` | `PreloadNext3Capped` | 4 | Deeper preloading helps fast scrollers; capped buffers should contain the memory cost. |
| `preload3-uncapped` | `PreloadNext3Uncapped` | 4 | Negative control for the **buffer cap**. Same depth, same pool, system-default buffers. |
| `window` | `PreloadWindow` | 4 | Preparing backward too should help back-scroll TTFF; costs a slot. |
| `pool-unbounded` | `PreloadNext1` | ∞ | Deliberate negative control — demonstrates *why* bounding exists (memory, dropped frames). |

**Two arms exist to lose, and they lose for different reasons.** `preload3-uncapped` is paired with
`preload3-capped` because that pair is the only one that isolates the buffer cap: `preload3-capped`
differs from `preload1` in *two* ways at once — more depth and capped buffers — so any difference
between those two is unattributable. Holding depth and capacity fixed and varying only the
configuration is what makes "capping is what makes deep preload viable" a measurement rather than a
retelling of the M2 macOS probe.

`pool-unbounded` is the arm that makes the point: it should look fine on TTFF and bad on memory and dropped frames. A rig that only tests good ideas proves nothing.

## Assignment

Manual selection from the debug menu, applied on dismissal. Selecting an arm **resets the session**
and **returns the feed to the first item** — both halves matter:

- *Reset* because records carry the arm name and peak memory is a **session** figure. A session
  spanning two arms would attribute half its items to the wrong condition, and its memory peak to
  neither. Records, buffered events, and the memory peak are all discarded; the pool is replaced
  rather than resized, since capacity is part of what an arm *is*.
- *Scroll to top* because the run protocol below requires the same item order for every arm. A fresh
  session resuming at item 14 would produce first records incomparable with another arm's, and the
  warm-up item that step 5 says to discard would not be the same item.

Not randomized. This is a single-operator measurement rig, not a live A/B test — randomization would add variance without adding validity at n=1 user. **Say this explicitly in the README**; conflating a manual comparison rig with a real online experiment is the kind of overclaim a reviewer will catch.

The harness is nonetheless structured the way an online experiment would be — named arms, per-arm records, aggregate comparison — so the methodology transfers.

## Run protocol (must be identical across arms)

Documented in `testing.md` and followed for every published number:

1. Physical device, same device for all arms, screen brightness and thermal state comparable, other apps closed.
2. Same content manifest and same item order.
3. Same scroll script: a fixed sequence (e.g. 20 items forward at ~2s dwell, 5 back, 5 forward fast-scroll), performed as consistently as possible — note in the README that scroll input is human and therefore approximate.
4. Same network condition, set via Network Link Conditioner. Run each arm under at least two profiles: unthrottled Wi-Fi and a constrained profile (e.g. 3G / high-latency).
5. Cold start before each arm; discard the first item's record as a warm-up outlier (and say so).
6. Repeat each arm ≥3 times; report median of runs.

## Comparison

The dashboard renders arms side by side on the metric set from `qoe-metrics.md`. Report **p90 TTFF and aggregate rebuffer ratio as the headline pair** — startup and smoothness are the two things users feel, and they trade against each other.

Honesty rules for the README:
- Report n (runs per arm) and the network profile alongside every number.
- Report the arms that lost, not only the winner.
- If two arms are within run-to-run variance, say they're indistinguishable rather than declaring a winner. Include the observed spread.
