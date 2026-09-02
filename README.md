# anvil

Terminal-UI-Library für Crystal, mit zwei Betriebsarten:

- **Inline** — der Scrollback bleibt erhalten, nur eine Live-Region am unteren Rand wird
  neu gezeichnet. Fertige Inhalte wandern einmal in die History und bleiben dort kopier-
  und durchsuchbar. Das Modell von [smith](https://github.com/webmatze/smith) und
  Claude Code.
- **Fullscreen** — Alternate Screen, die App besitzt das Raster. Für Animation und
  Vollbild-Werkzeuge, gemessen flickerfrei bei 60 fps.

Beide teilen sich alles oberhalb der Zeichenfläche: Text, Blöcke, Eingabe, Schleife.

Unterbau ist [termisu](https://github.com/omarluq/termisu) — ausgewählt nach einem
Vergleich gegen crysterm, skuznetsov/crystal_tui und handgeschriebenen Code, siehe
[BENCHMARK.md](BENCHMARK.md).

## Beispiel

```crystal
require "anvil"
include Anvil

backend = Backend.new(alternate_screen: false)
surface = Surface::Inline.new(backend, height: 1)
app = App.new(surface, Loop.for(backend, target_fps: 20))

app.status = ->(width : Int32) { Text.line("bereit", Text::Style.new(fg: Text::Palette::ACCENT)) }

app.run do |input|
  app.add_block(View::TextBlock.new("❯ #{input}"))
  app.idle!
end
```

Eine vollständige App mit streamenden Blöcken, Werkzeug-Zuständen und einer modalen
Rückfrage mitten im Vorgang: `crystal run examples/agent_demo.cr`.

## Aufbau

```
Backend      Terminal · Raw-Mode · Eingabe · Ereignisse · Signal-Aufräumen
Surface      Fullscreen │ Inline │ Memory (für Tests)
Text         Style · Span · StyledLine · wrap · truncate · Palette
View         Block · Segment · Region.compose (Drop-Priorität)
Widgets      InputEditor · ListPopup
Loop         Takt · Drift-Korrektur · Resize-Entprellung
App          Blöcke · Live-Region · Modals · Zustandsmaschine
```

Bewusst nicht enthalten: CSS, Layout-Engine, Widget-Zoo. Layout bleibt beim Aufrufer —
eine Liste von `StyledLine` und die Regel, was auf kleinem Schirm zuerst weicht.

## Was es kostet

| | |
|---|---|
| Binary (gestrippt, gleiche App) | 0,97 MB — gegenüber 0,60 MB handgeschrieben, 35,4 MB crysterm |
| Bytes pro Redraw (Region 15 Zeilen, 2 bewegt) | 118 |
| Bytes pro Vollbild-Frame (200×50, Dashboard) | 6 836 — identisch mit direktem termisu |
| Build | Sekunden |

## Entwicklung

```sh
mise install && shards install
crystal spec                      # 68 Specs, kein Terminal nötig
python3 examples/check_demo.py    # vollständige Sitzung durch ein PTY
python3 bench/restore_check.py anvil   # Aufräumen bei Signal
FRAMES=600 bench/run.sh && bench/report.py   # Leistungs-Regression
```

Der Benchmark ist Regressionstest: `bin/anvil` muss die Zahlen von `bin/baseline`
(handgeschrieben, ohne Library) halten.

Entwurf und Begründungen: [DESIGN.md](DESIGN.md) ·
Anforderungen aus smith: [SMITH-REQUIREMENTS.md](SMITH-REQUIREMENTS.md)
