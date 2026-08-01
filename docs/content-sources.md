---
type: reference
title: Content Sources and Licensing
description: The licensed test streams FeedLab uses, why each is included, and the attribution required
status: living
tags: [content, licensing, hls, attribution]
timestamp: 2026-08-01T00:00:00Z
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

## Manifests

`Content/manifests/*.json`, keyed by scenario:
- `short-form.json` — many short clips, the fast-scroll case the preload strategies target.
- `long-form.json` — fewer, longer HLS assets; better for ABR and stall behavior.
- `mixed.json` — deliberately heterogeneous (resolutions, ladders, durations) to stress the engine.

Manifest entry:

```json
{
  "id": "bbb-1080",
  "title": "Big Buck Bunny (excerpt)",
  "url": "https://.../playlist.m3u8",
  "source": "Blender Foundation",
  "license": "CC BY 3.0",
  "attribution": "© Blender Foundation | www.bigbuckbunny.org"
}
```

`license` and `attribution` are **required** fields — an item without them must fail manifest validation rather than silently play.

## Attribution surfaces

- Long-press on a feed item shows title, source, license, attribution.
- A Credits screen in the debug menu lists every manifest entry's attribution.
- The README carries a Content & Licensing section naming each source.
