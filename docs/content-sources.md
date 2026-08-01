---
type: reference
title: Content Sources and Licensing
description: The licensed test streams FeedLab uses, why each is included, and the attribution required
status: living
tags: [content, licensing, hls, attribution]
timestamp: 2026-08-01T19:07:52Z
related: [product-spec.md, testing.md]
---

# Content Sources

FeedLab ships **no video files** — only a manifest of URLs to publicly available, licensed test content. This is both a legal requirement and a repo-hygiene one.

## Hard rule

Never source video from Reddit, YouTube, TikTok, Instagram, X, or any consumer platform. It violates their terms and the content's copyright, and for a portfolio project aimed at media companies it is precisely the wrong signal. Only the categories below.

## Approved sources

| Source | What it's good for | Licensing |
|---|---|---|
| **Apple HLS test streams** (the "BipBop" bundle from Apple's developer streaming docs/examples) | Canonical multi-variant HLS with a real bitrate ladder — the ABR and switch metrics need this | Apple-published developer test assets; reference by URL, don't rehost |
| **Mux public test streams** | Additional HLS variants, reliable CDN | Publicly published test assets; reference by URL |
| **Blender Foundation open movies** — Big Buck Bunny, Sintel, Tears of Steel, Elephants Dream | Real encoded content at varied lengths/resolutions; progressive MP4 and some HLS mirrors | Creative Commons Attribution — **attribution required** |
| **NASA imagery/video** | Public-domain footage, visually distinct | Generally public domain; check the specific asset's usage guidelines |

Prefer HLS over progressive MP4 for the primary manifest: ABR, variant switching, and most access-log fields only mean something with a real ladder. Keep a small progressive set as a contrast case and note the difference in the learning notes.

## What is actually reachable (verified 2026-08-01)

Every URL below was probed with a range request before being committed. Findings that contradict the
common tutorial advice:

**Working, and content identifiable:**

| URL family | Content | Notes |
|---|---|---|
| `devstreaming-cdn.apple.com/.../bipbop_16x9/`, `bipbop_4x3/` | Apple BipBop | 6-variant ladder, 416×234 @264 kbps → 1920×1080 @1.92 Mbps, plus an audio-only rendition. The best ABR test case available. |
| `devstreaming-cdn.apple.com/.../img_bipbop_adv_example_fmp4/` | Apple BipBop advanced | 8 variants to 1920×1080 @8 Mbps, 60 fps, fMP4 segments |
| `devstreaming-cdn.apple.com/.../adv_dv_atmos/` | Apple Dolby Vision / Atmos | HDR + spatial audio path |
| `stream.mux.com/v69RSHhFelSm…` | Mux published test asset | |
| `demo.unified-streaming.com/.../tears-of-steel.ism/.m3u8` | Tears of Steel (Blender, CC BY) | |
| `test-streams.mux.dev/tos_ismc/` | Tears of Steel, alternate packaging | |
| `images-assets.nasa.gov/video/<id>/<id>~medium.mp4` | NASA, public domain | Resolve via `images-api.nasa.gov/search?media_type=video`; ids contain spaces and must be percent-encoded |

**Dead or unusable — do not re-add without re-probing:**

- `download.blender.org` — 403 to programmatic requests (serves a ~61 KB block page). The authoritative
  Blender mirrors are therefore *not* usable; Blender content survives only as Tears of Steel over HLS.
- `commondatastorage.googleapis.com/gtv-videos-bucket/*` — 403. Widely cited in tutorials; not available.
- `bitdash-a.akamaihd.net/content/sintel/hls/` — 403.
- Wikimedia's Big Buck Bunny transcodes — VP9/WebM, which `AVPlayer` will not decode.
- `test-streams.mux.dev/x36xhzz/`, `pts_shift/`, `test_001/`, `dai-discontinuity-deltatre/` — reachable, but
  **excluded on principle**: the underlying content and its license cannot be identified. "Hosted by Mux"
  is not the same as "licensed for our use," and the last is broadcast footage. Being reachable is not
  being permitted.

### Consequence for the corpus

Publicly available HLS whose content licensing can actually be named is scarce — about seven distinct
streams. `short-form.json` is therefore **7 HLS + 15 NASA progressive MP4**, inverting the HLS preference
stated above. This is a real limitation, not an oversight:

- ABR metrics (`indicatedBitrate`, bitrate-switch count) are only valid over the HLS subset. `Manifest.hlsItems`
  exists to make that subset addressable, and aggregates must use it rather than reporting a switch count
  of zero for progressive items as if it were a good result.
- TTFF, rebuffer ratio, stall count, dropped frames, and peak memory remain valid across the whole corpus.
- The NASA assets are longer than "short-form" implies. This matters less than it sounds: the run protocol
  uses a fixed ~2 s dwell, so no item is ever watched to completion under measurement.

## Manifests

`Content/manifests/*.json`, keyed by scenario:
- `short-form.json` — the fast-scroll case the preload strategies target. *(Populated, 22 items.)*
- `long-form.json` — fewer, longer HLS assets; better for ABR and stall behavior.
- `mixed.json` — deliberately heterogeneous (resolutions, ladders, durations) to stress the engine.

A manifest is an object, not a bare array — the debug menu needs a display name per corpus, and item
**order is significant** because the run protocol requires the same order across every arm:

```json
{
  "id": "short-form",
  "title": "Short-form mixed",
  "items": [
    {
      "id": "tos-unified-streaming",
      "title": "Tears of Steel",
      "url": "https://demo.unified-streaming.com/.../tears-of-steel.ism/.m3u8",
      "source": "Blender Foundation",
      "license": "CC BY 3.0",
      "attribution": "(CC) Blender Foundation — mango.blender.org | hosted by Unified Streaming"
    }
  ]
}
```

`license` and `attribution` are **required** fields — an item without them must fail manifest validation
rather than silently play. So are `id`, `title`, `url`, and `source`; a whitespace-only value counts as
absent, since `"attribution": "  "` satisfies a non-nil check while crediting nobody. URLs must be HTTPS
(see `decisions.md`). Duplicate item ids are rejected because `PlaybackRecord`s are keyed by item id.

## Attribution surfaces

- Long-press on a feed item shows title, source, license, attribution. *(Pending.)*
- A Credits screen in the debug menu lists every manifest entry's attribution, grouped by rights holder.
  *(Done, M1.)*
- The README carries a Content & Licensing section naming each source. *(Done.)*
- Each feed cell shows its attribution line directly. *(Done, M1 — not originally required, but it makes
  every screenshot self-crediting.)*
