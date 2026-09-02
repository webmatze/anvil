# anvil

A terminal UI library for Crystal, with two modes of operation:

- **Inline** — the scrollback stays intact; only a live region at the bottom is
  redrawn. Finished content is written to the history once and stays there,
  copyable and searchable like any other terminal output. This is the model
  [smith](https://github.com/webmatze/smith) and Claude Code use.
- **Fullscreen** — alternate screen, the app owns the grid. For animation and
  full-screen tools; measured tear-free at 60 fps.

Only the drawing surface knows which mode it is in. Everything above it — text,
blocks, input, the loop — is shared.

Built on [termisu](https://github.com/omarluq/termisu), chosen after measuring it
against crysterm, skuznetsov/crystal_tui and hand-written code. What decided it was
bytes per frame, binary size and build time — not peak frame rate. The numbers are in
[BENCHMARK.md](BENCHMARK.md).

## Installation

```yaml
dependencies:
  anvil:
    github: webmatze/anvil
    version: ~> 0.1.0
```

## Example

```crystal
require "anvil"
include Anvil

backend = Backend.new(alternate_screen: false)
surface = Surface::Inline.new(backend, height: 1)
app = App.new(surface, Loop.for(backend, target_fps: 20))

app.status = ->(width : Int32) { Text.line("ready", Text::Style.new(fg: Text::Palette::ACCENT)) }

app.run do |input|
  app.add_block(View::TextBlock.new("❯ #{input}"))
  app.idle!
end
```

A complete app — streaming blocks, tool states, and a modal question asked in the
middle of the work — is in `examples/agent_demo.cr`:

```sh
crystal run examples/agent_demo.cr
```

## Layout

```
Backend      terminal · raw mode · input · events · signal cleanup
Surface      Fullscreen │ Inline │ Memory (for tests)
Text         Style · Span · StyledLine · wrap · truncate · Palette
View         Block · Segment · Region.compose (drop priority)
Widgets      InputEditor · ListPopup
Loop         tick · drift correction · resize debounce
App          blocks · live region · modals · state machine
```

Deliberately absent: CSS, a layout engine, a widget zoo. Layout stays with the caller —
a list of `StyledLine` and a rule for what gives way first on a small screen. That
restraint is the point: crysterm, which does include all of it, costs 35 MB of binary
and 25 minutes of release build.

## What it costs

| | |
|---|---|
| Binary (stripped, same app) | 0.97 MB — against 0.60 MB hand-written, 35.4 MB crysterm |
| Bytes per redraw (15-line region, 2 lines moving) | 118 |
| Bytes per fullscreen frame (200×50, dashboard) | 6,836 — identical to raw termisu |
| Build | seconds |

The interesting one is the second: in a live region the height is nearly free, only
change costs. A 40-line region with two moving lines costs 137 bytes, a 15-line region
with the same two costs 118.

## Development

```sh
mise install && shards install
crystal spec                            # 104 specs, none of them need a terminal
python3 examples/check_demo.py          # a full session through a real PTY
python3 examples/check_inline.py        # inline rendering: scrollback, growth, commit
python3 bench/restore_check.py anvil    # terminal restored on exit and on SIGINT
FRAMES=600 bench/run.sh && bench/report.py   # performance regression
```

The benchmark doubles as a regression test: `bin/anvil` has to hold the numbers of
`bin/baseline`, which is the same renderer written by hand with no library at all.

Design decisions and their reasoning: [DESIGN.md](DESIGN.md) ·
Where the requirements came from: [SMITH-REQUIREMENTS.md](SMITH-REQUIREMENTS.md)

## License

MIT
