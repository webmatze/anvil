# What the library has to do, minimally, to carry smith

An analysis of `webmatze/smith` v0.3.0 (16,602 LOC total, 2,687 of them in
`src/smith/ui/`). Written before the library existed; kept because it is where the
requirements came from.

## The finding that changed the shape of it

**smith is not an alternate-screen app.** From its own comment in `src/smith/ui/app.cr`:

> Rendering model (same as Claude Code): finished blocks are flushed into the normal
> scrollback once; the live region at the bottom — streaming text, running tools, status
> bar, input — is redrawn in place every tick. No alternate screen, so the transcript
> stays in the terminal's scrollback and can be copied and searched like any other output.

That is a fundamentally different model from the one the benchmark measured:

| | Fullscreen (benchmarked) | Inline (smith) |
|---|---|---|
| Screen | alternate screen, app owns the whole grid | the normal scrollback |
| Addressing | absolute rows, `ESC[y;xH` | relative, `ESC[nA` plus erase from the cursor |
| State | one cell buffer over the full height | finished blocks move into the history, only the bottom *n* rows are alive |
| Height | fixed (terminal height) | variable, changes with the content every frame |
| Scrollback | none (alternate screen) | is the feature |

**termisu cannot do this mode.** `Termisu.new` unconditionally enters the alternate
screen, and `Buffer#render_to` addresses rows absolutely from 0.

The good news: `Termisu::Renderer` is a clean abstract class, and
`Buffer#render_to(renderer)` accepts any implementation of it. So the inline mode is
**a renderer of its own**, translating `move_cursor(x, y)` into relative movement inside
a region anchored at the bottom — not a fork of termisu. That is the single most
important building block of the library.

## Minimum inventory

### 1. Backend / terminal
| Element | From where |
|---|---|
| Raw mode without `ISIG`/`ICRNL` (Ctrl-C as a key, Enter ≠ Ctrl-J) | **termisu** ✓ (`termios.cr`, correctly solved) |
| Size via `TIOCGWINSZ`, falling back to `COLUMNS`/`LINES` | **termisu** ✓ (fallback missing, ~5 lines) |
| Bracketed paste | **termisu** ✓ |
| Entering / leaving the alternate screen | **termisu** ✓ |
| **Terminal restore on `INT`/`TERM` plus `at_exit`** | **us** — termisu traps only `WINCH`; smith does it itself today |

### 2. Two rendering modes
| Element | From where |
|---|---|
| Cell buffer with diff, wide characters, grapheme clusters | **termisu** ✓ |
| Synchronized output (DEC 2026) | **termisu** ✓ |
| Fullscreen mode (alternate screen, absolute grid) | **termisu** ✓ |
| **Inline mode: a `Renderer` implementation with relative addressing** | **us** — the core |
| **Live region with a variable height** | **us** — smith's `clear_drawn!` / `draw!` cycle |
| **Committing finished content to the scrollback** (once, never redrawn) | **us** — smith's `flush_blocks!` |
| **A full rebuild on request** (Ctrl-L, after a resize) | **us** — smith's `redraw_all!` |

### 3. The styled-text layer
termisu is a *cell* buffer and knows nothing of lines, spans or wrapping. smith built all
of it itself (`style.cr`, 263 LOC) — and it belongs in the library:

| Element | From where |
|---|---|
| `Style` (256-color fg, bold, dim, italic, underline) with `merge` | **us** (termisu supplies `Color`/`Attribute` as the parts) |
| `Span` = text + style, `StyledLine` = `Array(Span)` | **us** |
| `display_width` / `char_width` including CJK and emoji | **termisu** ✓ (`unicode_width.cr`) — smith's own implementation goes away |
| **`wrap(line, width)`** — wrapping across span boundaries | **us** |
| **`truncate(line, width, ellipsis)`** | **us** |
| Rendering a `StyledLine` into the cell buffer *and* as an ANSI string | **us** |
| A palette (named color roles instead of numbers) | **us** |

### 4. The block / content model
| Element | From where |
|---|---|
| `Block` base: `lines(width) : Array(StyledLine)` plus `finalized?` | **us** — generic |
| Lifecycle live → finalized → committed to the scrollback | **us** |
| The concrete blocks (assistant, tool, todos, thinking, notice) | **stays in smith** — domain |
| Markdown → `StyledLine` (`markdown.cr`, 232 LOC) | **optional** — generic enough, but not required for v1 |

### 5. Input
| Element | From where |
|---|---|
| Key parsing including CSI, SS3, UTF-8, Alt+key | **termisu** ✓ — covers smith's `KeyParser` (215 LOC) completely |
| Home/End/Delete/PageUp/F1–F24 | **termisu** ✓ |
| A `Tick` event while idle (a poll window with no input) | **termisu** ✓ (timer source) |
| Resize events | **termisu** ✓ |
| **Line editor**: cursor, history (↑/↓), Ctrl-A/E/B/F/U/K/W, paste flattening | **us** — smith's `input_editor.cr`, 169 LOC |
| **Filter popup** (the slash-command palette: query, selection, window) | **us** — smith's `completions.cr`, 88 LOC, generically a list popup |

### 6. The app loop
| Element | From where |
|---|---|
| Event loop with a timeout poll | **termisu** ✓ |
| **Fixed timestep with drift correction** | **us** — confirmed by the benchmark: termisu's timers run 3–4 % off |
| **A dirty flag instead of an unconditional redraw** | **us** — smith's `mark_dirty` / `needs_draw?` |
| **Resize debounce** (dragging delivers one `WINCH` per step; smith waits out 3 quiet poll windows, or it flickers) | **us** — smith's `RESIZE_SETTLE_TICKS` |
| **State machine** idle / busy / modal-char / modal-text / done | **us** |
| **A modal question over a `Channel`** blocking an *other* fiber while the key loop keeps running | **us** — indispensable for tool approval, the plan gate and the trust prompt |
| **A synchronous modal** before the main loop starts | **us** — smith needs it for the trust prompt |
| Ctrl-L (rebuild), double Ctrl-C (interrupt → abort) | **us** |
| Cursor placement in the input line, horizontal scrolling included | **us** |

## What that meant for smith

Replaceable by the library: **~1,790 LOC** of smith's 2,687 UI lines — `terminal.cr`
(403), `style.cr` (263), `input_editor.cr` (169), `completions.cr` (88) and most of
`app.cr` (868). With `markdown.cr` it would be ~2,020.

Staying in smith: `renderer.cr` (event stream → blocks), `gates.cr` (approver, plan gate,
trust prompt), `presentation.cr`, the concrete block types from `view_model.cr` and the
contents of the status bar. All domain, none of it belonging in a TUI library.

## Consequences for the plan

1. **Inline mode is not a follow-up, it is equal in rank.** With smith as the
   integration target it has to be in v1 — otherwise the library does not carry the
   project. A pure fullscreen wrapper around termisu would be worthless to smith.
2. **The benchmark measured the wrong mode.** Its numbers still hold for fullscreen
   apps; for smith's inline model the relevant quantity is not "bytes per full-screen
   frame" but "bytes per redraw of the live region" (typically 10–20 lines). `bench/`
   should gain an inline scenario once the renderer exists.
3. **The styled-text layer is the largest thing to build ourselves** and does not exist
   in termisu at all. It is also what costs smith the most code today.
4. **termisu's contribution stays substantial regardless**: key parsing, Unicode widths,
   the cell diff, raw-mode details, bracketed paste — together the most error-prone part.
