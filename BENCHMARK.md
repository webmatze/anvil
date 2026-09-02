# Benchmark: what to build a tear-free fullscreen TUI on in Crystal

Measured on macOS (Apple Silicon), Crystal 1.21.0, release builds, 200×50 cells, true
color, 600 frames per run, headless over a PTY of a fixed size.

Priorities, in order: **tear-free rendering** and **small binaries**. Absolute frame rate
is secondary as long as 30–60 fps is held reliably.

## Recommendation

**A thin layer of our own on [termisu](https://github.com/omarluq/termisu).**

termisu is the best candidate on bytes per frame in both scenarios — and under
synchronized output that is the quantity which decides tearing. It costs 0.97 MB of
binary against 0.60 MB for hand-written code, and gives back the complete input stack,
wide-character handling and a tick timer. What has to be added is modest and already
demonstrated in `bench/baseline.cr`: a fixed-timestep loop with drift correction, and a
signal handler that restores the terminal.

Against the alternatives:

- **crysterm** is out despite being the most capable technically: 35 MB of binary (59×
  termisu), ~25 minutes of release build, and it does not hold the frame rate it is
  asked for.
- **sk_tui** is surprisingly small (0.68 MB) but spends 74 % more bytes per frame than
  termisu — exactly the wrong direction for the primary criterion.
- **From scratch** is defensible (0.60 MB, exact cadence, zero third-party dependency),
  but the 0.37 MB premium buys input parsing, bracketed paste, grapheme clusters and
  wide-character handling — all things that look small individually and add up to weeks
  of detail work.

## Tearing

All four implementations behave correctly in the basics:

| Impl | Sync markers per frame | Full-screen erases while running | Cursor hidden |
|---|---:|---:|---|
| baseline | 120/120 | 0 | yes |
| termisu | 120/120 | 0 | yes |
| sk_tui | 120/120 | 0 | yes |
| crysterm | 120/120 | 0 | yes |

Each wraps every frame in DEC 2026 synchronized output (`ESC[?2026h/l`) and never clears
the screen while running. On Ghostty, which supports DEC 2026, none of them should tear.

That moves the tearing question onto two other quantities:

**1. Bytes per frame.** Under synchronized output the terminal holds the frame back until
the end marker arrives — the larger the frame, the longer that window. At 331 KB per
frame (fullscreen churn) that is 20 MB/s at 60 fps, more than a terminal ingests; the
effective frame rate then collapses whatever the app does. In the realistic dashboard
case:

| Impl | Bytes/frame | per changed cell |
|---|---:|---:|
| baseline | 6,785 | 17.2 |
| **termisu** | **6,795** | **17.3** |
| crysterm | 8,891 | 22.6 |
| sk_tui | 11,833 | 30.1 |

**2. Evenness of the cadence.** A frame that takes 16 ms once and 27 ms the next reads as
restless even when the average is right. Requested against achieved (dashboard):

| Impl | Target 30 | Target 60 |
|---|---:|---:|
| baseline (fixed timestep) | 30.0 | 60.0 |
| termisu (sleep timer) | 29.6 | 58.2 |
| termisu (kernel timer, kqueue) | 30.3 | 62.4 |
| sk_tui (own loop, like baseline) | 30.0 | 60.0 |
| **crysterm** | **50.3** | **52.7** |

crysterm ignores the requested tick: its render loop coalesces frames by its own logic
and renders too many at a target of 30, too few at 60. Both of termisu's timers run 3–4 %
off and need drift correction in a library layer — the baseline's fixed-timestep loop
(`bench/baseline.cr`, `next_at += interval`) hits the target exactly and is ~10 lines.

What this measurement does *not* show is how it looks. The PTY in the harness is drained
by a reader that draws nothing; a real terminal is slower. For tearing and perceived
calm: `bench/interactive.sh <impl> <scenario> <fps>` in a real terminal.

## Interactive confirmation (Ghostty, real terminal)

Both scenarios, 95×28 cells, 600 frames:

| | `dashboard` | `churn` |
|---|---|---|
| achieved | 58.3 fps (target 60) | 58.1 fps (target 60) |
| frame time p50 | 1.08 ms | 3.05 ms |
| p95 / p99 | 1.66 / 2.08 ms | 4.86 / 5.77 ms |
| missed ticks | 0 | 0 |
| bytes/frame (computed) | ~1.6 KB | ~83 KB |
| tearing | none | none |
| terminal afterwards | cleanly restored | cleanly restored |

This matches the headless measurement: frame time scales with the cell count (95×28 ≈
2,660 cells against 10,000 in the test grid), and the sleep timer runs 3 % slow in a real
terminal too — so the drift correction is genuinely needed, not an artifact of the
harness.

The churn case is the stress test: every cell changes every frame, ~83 KB per frame or
~4.8 MB/s. Ghostty handles it with no visible tearing and without a single missed tick —
at a p99 of 5.8 ms there is over 10 ms of headroom in the 16 ms budget.

**Important for scaling:** that headroom depends on the window size. The same scenario at
200×50 is 313 KB per frame, so 18 MB/s at 60 fps — there the frame rate collapses,
whatever the library. A fullscreen effect in which truly every cell changes is not
available at 60 fps on large terminals; anything touching less than ~5 % of the cells per
frame is comfortably in the clear.

## Binary size

The same app (fullscreen renderer, both scenarios), release build, stripped:

| Impl | Binary | vs. baseline |
|---|---:|---:|
| baseline (no library) | 0.60 MB | 1.0× |
| sk_tui | 0.68 MB | 1.1× |
| termisu | 0.97 MB | 1.6× |
| crysterm | 35.36 MB | 59× |

A minimal app that merely requires the library: baseline 0.44 MB · sk_tui 0.51 MB ·
termisu 0.86 MB.

Crystal only generates reachable code — which is why sk_tui's widget and CSS layer costs
nothing while unused, despite the library being 29,000 LOC. That does not save crysterm:
a single `Box` with a paint handler already drags in 35 MB, because the CSS engine, 12
layout engines and the media backends come along unconditionally.

## Full measurement matrix

### Scenario `churn` — 10,000 changed cells/frame

| Impl | Variant | Target | Achieved fps | p50 ms | p95 ms | p99 ms | Bytes/frame | B/cell | CPU % | Missed |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline | default | 30 | 30.0 | 6.95 | 8.65 | 15.65 | 331 655 | 33.2 | 14.8 | 2 |
| baseline | nosync | 30 | 30.0 | 7.08 | 8.88 | 9.73 | 331 639 | 33.2 | 15.6 | 2 |
| crysterm | default | 30 | 40.2 | 5.53 | 8.03 | 8.71 | 320 835 | 32.1 | 20.0 | 0 |
| crysterm | nosync | 30 | 38.3 | 6.66 | 11.11 | 13.39 | 320 284 | 32.0 | 22.0 | 0 |
| sk_tui | default | 30 | 30.0 | 7.02 | 9.64 | 10.32 | 381 220 | 38.1 | 24.7 | 0 |
| sk_tui | nosync | 30 | 30.0 | 7.29 | 9.82 | 10.60 | 381 204 | 38.1 | 25.4 | 0 |
| termisu | default | 30 | 29.6 | 7.25 | 8.78 | 9.41 | 312 582 | 31.3 | 13.5 | 0 |
| termisu | nosync | 30 | 29.6 | 7.34 | 8.84 | 9.52 | 312 566 | 31.3 | 13.8 | 0 |
| termisu | systimer | 30 | 30.3 | 7.53 | 8.95 | 9.59 | 312 582 | 31.3 | 14.2 | 0 |
| baseline | default | 60 | 60.0 | 6.94 | 8.59 | 12.17 | 331 655 | 33.2 | 29.7 | 5 |
| baseline | nosync | 60 | 60.0 | 6.89 | 8.17 | 9.55 | 331 639 | 33.2 | 28.9 | 3 |
| crysterm | default | 60 | 36.5 | 10.15 | 12.38 | 16.52 | 321 371 | 32.1 | 24.2 | 0 |
| crysterm | nosync | 60 | 35.9 | 10.25 | 12.23 | 15.24 | 321 355 | 32.1 | 24.7 | 0 |
| sk_tui | default | 60 | 60.0 | 7.19 | 8.97 | 10.99 | 381 220 | 38.1 | 47.9 | 0 |
| sk_tui | nosync | 60 | 60.0 | 7.00 | 10.26 | 11.95 | 381 204 | 38.1 | 48.9 | 1 |
| termisu | default | 60 | 58.4 | 6.70 | 8.27 | 10.89 | 312 582 | 31.3 | 23.0 | 0 |
| termisu | nosync | 60 | 58.4 | 6.89 | 8.17 | 10.52 | 312 566 | 31.3 | 23.7 | 0 |
| termisu | systimer | 60 | 62.4 | 6.77 | 7.94 | 8.86 | 312 582 | 31.3 | 25.2 | 0 |

### Scenario `dashboard` — 394 changed cells/frame

| Impl | Variant | Target | Achieved fps | p50 ms | p95 ms | p99 ms | Bytes/frame | B/cell | CPU % | Missed |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline | default | 30 | 30.0 | 0.44 | 0.85 | 1.32 | 6 785 | 17.2 | 1.5 | 0 |
| baseline | nosync | 30 | 30.0 | 0.51 | 1.29 | 1.88 | 6 769 | 17.2 | 1.6 | 0 |
| crysterm | default | 30 | 50.3 | 0.70 | 1.50 | 2.69 | 8 874 | 22.5 | 2.9 | 0 |
| crysterm | nosync | 30 | 50.3 | 0.87 | 1.73 | 2.45 | 8 875 | 22.5 | 3.7 | 0 |
| sk_tui | default | 30 | 30.0 | 2.54 | 4.07 | 5.29 | 11 833 | 30.1 | 7.0 | 0 |
| sk_tui | nosync | 30 | 30.0 | 2.57 | 4.75 | 5.61 | 11 817 | 30.0 | 7.4 | 0 |
| termisu | default | 30 | 29.6 | 2.73 | 4.74 | 5.82 | 6 795 | 17.3 | 8.7 | 0 |
| termisu | nosync | 30 | 29.6 | 3.16 | 5.88 | 6.61 | 6 779 | 17.2 | 10.1 | 0 |
| termisu | systimer | 30 | 30.3 | 3.22 | 5.67 | 6.41 | 6 795 | 17.3 | 9.5 | 0 |
| baseline | default | 60 | 60.0 | 0.41 | 0.83 | 1.07 | 6 785 | 17.2 | 2.8 | 0 |
| baseline | nosync | 60 | 60.0 | 0.42 | 0.81 | 1.32 | 6 769 | 17.2 | 2.9 | 0 |
| crysterm | default | 60 | 52.7 | 0.73 | 1.46 | 2.05 | 8 891 | 22.6 | 3.3 | 0 |
| crysterm | nosync | 60 | 52.6 | 0.74 | 1.53 | 2.35 | 8 875 | 22.5 | 3.3 | 0 |
| sk_tui | default | 60 | 60.0 | 2.30 | 4.06 | 5.14 | 11 833 | 30.1 | 13.7 | 0 |
| sk_tui | nosync | 60 | 60.0 | 2.30 | 3.67 | 4.98 | 11 817 | 30.0 | 12.7 | 1 |
| termisu | default | 60 | 58.2 | 2.62 | 5.18 | 6.16 | 6 795 | 17.3 | 16.5 | 0 |
| termisu | nosync | 60 | 58.1 | 2.50 | 4.40 | 5.64 | 6 779 | 17.2 | 15.2 | 0 |
| termisu | systimer | 60 | 62.4 | 2.57 | 4.67 | 5.96 | 6 795 | 17.3 | 16.2 | 0 |

## Further observations that fed into the decision

**Signal handling.** termisu traps only `WINCH` — no `INT`, no `TERM`, no `at_exit`
restore. Measured directly (`bench/restore_check.py`): a signal leaves raw mode and the
alternate screen behind, with the cursor invisible. A normal exit restores cleanly.
sk_tui traps `INT` and `TERM` (read in the code, not measured — the benchmark bypasses
its `Terminal.init`); crysterm has a complete `at_exit` restore net. **For a library
built on termisu this is the first gap to close.**

**Build time.** termisu and sk_tui build in release in seconds, crysterm in ~25 minutes
(debug: 28 s). For iterative CLI development that is a price paid daily.

**Maturity and maintenance.** crysterm is at 1.0.0 and active (149★). termisu declares
itself pre-1.0 and "not battle tested", but is very active and visibly carefully built —
the cell buffer uses a packed `UInt128` identity key, per-row dirty ranges and interned
graphemes. sk_tui is young but moving daily; its hot path (`Buffer#set`) does contain two
`ENV[]` lookups per cell write and a `Set(Tuple(Int32,Int32))` for dirty tracking, and
`#flush` rebuilds every frame through `String.build` — which explains its extra bytes and
CPU.

**A correction to the initial research.** Contrary to its documentation, sk_tui does have
a front/back diff renderer (`Tui::Buffer#flush`), so it was measured rather than excluded.
crysterm is at 1.0.0 by now and installs on macOS without hand-holding — `unibilium` and
`gpm` cause no trouble.

## Limits of the method

- The widget and layout layers of crysterm and sk_tui are deliberately bypassed; what is
  measured is the renderer, not the scene graph. An app using their widgets is slower and
  larger than shown here.
- The PTY is drained by a reader that draws nothing. The numbers are therefore an upper
  bound on throughput, not a picture of a real terminal.
- `chunks_per_frame` in `flicker_check.py` measures the PTY buffer size (~1 KB), not the
  app's write granularity — useless as a tearing metric, kept only as a sanity check.
- crysterm's frame counting rests on `PreRender`/`Rendered`; since its loop coalesces on
  its own, its frames are not 1:1 the requested ticks.
