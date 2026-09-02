# Design: a reusable TUI library for Crystal

Grounded in [BENCHMARK.md](BENCHMARK.md) (choosing the foundation) and
[SMITH-REQUIREMENTS.md](SMITH-REQUIREMENTS.md) (what smith needs).

## Goal

A library that carries both modes of operation that actually get built:

- **Fullscreen** — alternate screen, the app owns the grid, 30/60 fps, tear-free.
- **Inline** — the scrollback stays, only a live region at the bottom is redrawn. The
  model smith and Claude Code use.

The foundation is [termisu](https://github.com/omarluq/termisu): measured best on bytes
per frame, 0.97 MB of binary, seconds of build time, and it supplies the most error-prone
parts ready-made (key parsing, Unicode widths, cell diff, raw-mode details).

## Name

`anvil`. A smith works at an anvil — the name pairs with `smith` and at the same time
describes what the library is: the surface things are shaped on (`Anvil::Surface`). Free
in the Crystal ecosystem; the working name `crystal_tui` was taken by
`skuznetsov/crystal_tui`. Published as `webmatze/anvil`.

## Architecture

```
                    termisu
   raw mode · key parsing · size · cell buffer + diff · Unicode widths
                       │
        ┌──────────────┴───────────────┐
        │      Anvil::Surface          │   ← the one seam separating the modes
        ├──────────────┬───────────────┤
        │  Fullscreen  │    Inline     │
        │  (alt screen)│ (live region) │
        └──────────────┴───────────────┘
                       │
   Anvil::Text     Style · Span · StyledLine · wrap · truncate · Palette
                       │
   Anvil::View     Block · region composition with drop priority
                       │
   Anvil::App      loop · state machine · modals · resize debounce · signals
                       │
   Anvil::Widgets  InputEditor · ListPopup
```

Only `Surface` knows the difference between the modes. Everything above it is shared —
which is the point at which the library pays off for both kinds of project.

## The two surfaces

A shared protocol: size, `put_cell` / `put`, `begin_frame` / `end_frame`, `invalidate!`,
plus the capabilities only inline really has (`commit`, `height=`, `max_height`,
`cursor_at`, `clear_screen`) with harmless defaults, so the same app layer runs on either.

**Fullscreen** is thin: `Termisu.new`, `set_cell`, `render`. The benchmark numbers apply
unchanged.

**Inline** is the part we build. termisu's facade unconditionally enters the alternate
screen in its constructor — but `Termisu::Terminal`, `Reader`, `Input::Parser`,
`Event::Loop` and the `Event::Source::*` classes are all public. So the stack is assembled
by hand, exactly as `Termisu#initialize` does, minus `enter_alternate_screen`.
**Verified.**

For drawing the region: `Buffer#render_to(renderer)` accepts any `Renderer`
implementation. `Anvil::InlineRenderer` translates `move_cursor(x, y)` into relative
movement inside the region — the interface passes `columns_advanced` through every
`write`, so cursor tracking is provided for.

That way the inline mode inherits termisu's cell diff, SGR coalescing and wide-character
logic instead of reimplementing them.

> **A correction to SMITH-REQUIREMENTS.md:** it says a line-level diff is the
> alternative. It is — but it gives away exactly the tested parts termisu was chosen for.
> The `InlineRenderer` is the better route. Should relative addressing prove awkward, the
> line diff (~60 lines) is the documented fallback. **Step 1 of the plan is precisely
> that test**, before anything is built on top.

Rules the inline mode has to keep (all learned from smith):

1. **One region line = exactly one terminal row.** Wrapping happens while composing, not
   while writing — otherwise clearing the old region falls out of step with the screen.
2. **The region height is variable.** Growing asks for rows with `\n` (the terminal
   scrolls); shrinking erases the surplus ones.
3. **Committing to the scrollback:** clear the region → write the finished blocks with
   `\n` → rebuild the region below them. Then `invalidate!`, because the screen has
   shifted underneath the front buffer.
4. **Foreign output corrupts the screen.** A subprocess writing to STDOUT invalidates the
   front buffer. `invalidate!` is the way out, and Ctrl-L the user-facing one. (An
   `IO` that routes such writes into notice blocks — smith has one as `NoticeIO` — is
   worth lifting into the library, but is not part of v1.)

## Modules and size

| Module | Content | estimated |
|---|---|---|
| `Anvil::Text` | `Style` (merge, ANSI), `Span`, `StyledLine`, `wrap` across span boundaries, `truncate`, `Palette`; widths from termisu's `unicode_width` | ~320 |
| `Anvil::Surface` | protocol + `Fullscreen` + `Inline` + `InlineRenderer` | ~380 |
| `Anvil::View` | the `Block` protocol (`lines(width)`, `finalized?`), region composition with drop priority (on a screen too small, the unimportant goes first) | ~180 |
| `Anvil::App` | loop, dirty flag, state machine, `Channel` modals, a synchronous modal, resize debounce, signal restore, Ctrl-L, double Ctrl-C | ~420 |
| `Anvil::Widgets` | `InputEditor` (history, Ctrl-A/E/B/F/U/K/W, paste flattening, horizontal scroll), `ListPopup` (filter, selection, window) | ~330 |
| `Anvil::Markdown` | optional, Markdown → `StyledLine` | ~230 |

Around 1,600 lines without Markdown. Replaces ~1,790 in smith.

## Build stages

Each stage ends runnable and verifiable.

### 1. Spike: InlineRenderer ✅ done
Assemble the termisu stack without the alternate screen, render a `Buffer` into a
five-line region at the bottom, grow and shrink it, commit text into the scrollback.

*Result:* it carries. `Anvil::InlineRenderer` (~90 lines) draws through termisu's
`Buffer`, addresses vertically relative (CUU/CUD) and horizontally absolute (CHA, since
the region always starts at column 0 — which saves all of the column bookkeeping).
`examples/check_inline.py` checks headlessly: no alternate screen, no full-screen clear,
scrollback complete and in order, 0 absolute cursor positionings. Confirmed in a real
terminal: growing 3→6, shrinking 6→2 and three commits with no remains and no flicker.
The line diff as a fallback is not needed.

### 2. `Anvil::Text` ✅ done
A pure data layer, testable entirely against `IO::Memory`. `wrap` is the delicate part:
wrapping across span boundaries while preserving styles, with CJK and emoji widths.

*Result:* `src/anvil/text.cr`. Widths come from `Termisu::UnicodeWidth` rather than a
second implementation — what counts as 79 columns here has to fit into 79 cells there.
`wrap` crosses span boundaries, breaks over-long words hard (the promise "no line is
wider than `width`" carries the inline region's height arithmetic), counts CJK and emoji
widths, and merges equally styled graphemes into one span so the renderer gets batches
rather than single cells.

### 3. `Anvil::Surface` ✅ done
*Result:* `Anvil::Backend` (terminal, input, event loop — shared by both modes, with the
alternate screen as a switch), `Anvil::Surface` as the protocol, `Surface::Fullscreen` and
`Surface::Inline`.

The benchmark is now a regression test (`bin/anvil`, 300 frames, 200×50, 60 fps):

| | churn p50 | churn B/frame | dashboard p50 | dashboard B/frame |
|---|---:|---:|---:|---:|
| raw termisu | 4.36 ms | 312,580 | 2.29 ms | 6,835 |
| through the surface | 4.42 ms | **312,581** | 1.63 ms | 6,836 |

The abstraction costs nothing: byte-identical but for the place where the frame number
has one more digit. The better frame time in the dashboard case does not come from the
surface but from the benchmark's fixed-timestep loop against termisu's tick loop — which
also hits the cadence better (59.9 instead of 57.8 fps), confirming the measured timer
drift.

The inline surface passes the same checks as the spike, now against production code
(`examples/inline_demo.cr`, `examples/check_inline.py`).

The signal handling in `Backend` closes the termisu gap the benchmark measured —
`bench/restore_check.py` on SIGINT:

| | leaves the alternate screen | cursor visible |
|---|---|---|
| raw termisu | no | no |
| through `Anvil::Backend` | **yes** | **yes** |

### 4. `Anvil::View` + `Anvil::Widgets` ✅ done
*Result:* `View::Block`/`TextBlock`, `View::Segment`/`Region.compose`,
`Widgets::InputEditor`, `Widgets::ListPopup(T)`. All specs run without a terminal — key
events are built directly in `spec/spec_helper.cr`.

Two things taken from smith's code that one otherwise learns the hard way:

- **The region must never be taller than the screen.** `cursor_up` stops at the top row,
  so a taller region could never be walked back over — every redraw would push another
  copy into the scrollback. `Surface::Inline#max_height` caps it, `Region.compose` drops
  unpinned lines (oldest first, behind a marker), and pinned ones — status bar, input
  line — always stay.
- **Bracketed paste has to be switched on** (`\e[?2004h` in `Backend`). Without it,
  pasted text is indistinguishable from typed text and a multi-line paste submits once
  per line. The editor handles `PasteStart`/`PasteEnd` and flattens newlines to spaces.

### 5. `Anvil::App` ✅ done
*Result:* `Anvil::Loop` (tick, drift correction, resize debounce) kept apart from
`Anvil::App` (blocks, live region, modals, state machine) — so a fullscreen application
can use the loop without the block machinery.

Two seams for testability that improved the architecture along the way: `Loop` takes its
event source as a `Proc` rather than a `Backend`, and `Surface::Memory` is a drawing
surface in memory. As a result `App` works against `Surface` rather than
`Surface::Inline`, and the specs need no terminal.

**A real bug the specs uncovered:** the parser delivers Ctrl keys as a key enum with an
empty `char` (Ctrl-A is `Key::LowerA` plus the modifier). The first draft read
`event.char` and would have matched *no* Ctrl key on a real terminal — neither Ctrl-L nor
the editor shortcuts. The spec helper now imitates the parser's behaviour exactly instead
of supplying a `char` and hiding the bug.

`bench/restore_check.py` confirms clean cleanup on a normal exit and on SIGINT;
`examples/check_demo.py` plays a complete session through a PTY (typing, streaming,
answering a modal question, quitting) and asserts on twelve properties of the output.

### 6. An inline scenario in the benchmark ✅ done
*Result:* `bench/inline_bench.cr`, 300 frames at 60 fps, 200 columns:

| Region | changed lines | bytes/redraw | p50 | CPU |
|---:|---:|---:|---:|---:|
| 15 | 2 | **118** | 0.082 ms | 1.5 % |
| 20 | 4 | 198 | 0.111 ms | 1.8 % |
| 40 | 2 | 137 | 0.188 ms | 2.6 % |

For comparison, the fullscreen dashboard at 200×50: 6,836 bytes per frame.

The finding behind it matters more than the absolute numbers: **the region height costs
almost nothing, only change costs.** A 40-line region with two moving lines costs 137
bytes, a 15-line one with the same two costs 118. The diff is working, and an inline app
is therefore about two orders of magnitude cheaper than a fullscreen redraw even at
60 fps.

## The smith migration, in two phases

**Phase A — no change to rendering.** smith replaces `style.cr`, `input_editor.cr` and
`completions.cr` with the library but keeps `terminal.cr` and `app.cr`. Pure data layers,
low risk, smith runnable throughout. Verified by the existing specs plus a visual check.

**Phase B — the loop.** `terminal.cr` and most of `app.cr` give way to `Anvil::App` with
`Surface::Inline`. What stays in smith is domain: `renderer.cr`, `gates.cr`, the concrete
block types, the contents of the status bar.

Separate phases because B is the risky one — a broken input loop makes the tool unusable,
and A establishes first that the data layers are right.

Both phases are done. Between them they took `src/smith/ui` from 2,699 to 1,392 lines,
and turned up three real bugs in anvil that neither the benchmark nor anvil's own specs
had found: the rebuild after a resize, animation stopping while busy, and the region
asking for too many rows after a commit. A library proves itself at its first real user,
not at its own tests.

## Test strategy

- **Data layers** (`Text`, `View`, `Widgets`) against `IO::Memory` — no terminal needed.
  smith extracted its `KeyParser` for exactly this reason; the pattern is kept.
- **Surfaces** against a renderer writing into a string: specs assert on the byte stream
  produced, not on pixels.
- **End to end** through `bench/pty_run.py` (a real PTY of fixed size),
  `examples/check_demo.py` and `bench/restore_check.py` (cleanup on a signal).
- **Performance** through `bench/run.sh` against `bin/baseline` as the regression
  threshold.

## What deliberately stays out

No CSS, no layout engine, no widget zoo. That is exactly the road on which crysterm ended
up at 98,000 LOC and a 35 MB binary. Layout stays with the caller: a list of `StyledLine`
and the rules for what disappears first on a small screen.
