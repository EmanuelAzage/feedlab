# Measurement runs

Raw session records, exactly as the app wrote them and as `devicectl device copy from` pulled them
off the device. One `<uuid>.session.json` per run, each holding the session summary, its per-item
records, and the raw event stream the records were folded from.

They are committed because the project's rule is that **every published number traces to a run**
(`docs/testing.md`). Keeping the events rather than only the conclusions has already paid for
itself once: the frozen-frame metric did not exist when the first runs were performed and was
derived retroactively from these files.

Regenerate the README table from any directory here:

```bash
Scripts/results_table.py measurements/<dir> --profile "unthrottled Wi-Fi"
```

| Directory | Runs | Conditions | What it settled |
|---|---|---|---|
| `2026-08-03-m4-buffer-cap` | 3 × `preload3-capped`, 3 × `preload3-uncapped` | iPhone 12 Pro, iOS 26.5.2, `Measure`, unthrottled Wi-Fi, **hand-driven** scroll | M4's memory question — capping the forward buffer made no measurable difference on device. See `docs/build-plan.md`. |

**The hand-driven runs are a separate population.** They predate the `FeedLabRunner` UI test target,
so their dwell is human (~8 s median, uncontrolled) and their peak-memory figures carry none of the
XCUITest accessibility overhead that runner-driven runs do. Do not pool them with runner output.

| `2026-08-04-hls-unthrottled` | 6 arms × 3 | unthrottled Wi-Fi, 5 s dwell, runner-driven | The unthrottled arm comparison in the README. |
| `2026-08-04-hls-dsl-2mbps` | 6 arms × 3 | DSL 2 Mbps, 10 s dwell, runner-driven | The constrained comparison. 10 s dwell because at 5 s most items never became current. |
| `2026-08-04-hud-perturbation` | `window` × 6 | 3 HUD-off / 3 HUD-on, alternating | M4's HUD criterion. Runs alternate, so the pair shares any drift; HUD state is not recorded in the session and is recovered from run order by `startedAt`. |
