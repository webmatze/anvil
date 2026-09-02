# Entwurf: eine wiederverwendbare TUI-Library für Crystal

Grundlage: [BENCHMARK.md](BENCHMARK.md) (Wahl des Unterbaus) und
[SMITH-REQUIREMENTS.md](SMITH-REQUIREMENTS.md) (was smith braucht).

## Ziel

Eine Library, die beide Betriebsarten trägt, die du tatsächlich baust:

- **Fullscreen** — Alt-Screen, App besitzt das Raster, 30/60 fps, flickerfrei.
- **Inline** — Scrollback bleibt erhalten, nur eine Live-Region am unteren Rand wird
  neu gezeichnet. Das Modell von smith und Claude Code.

Unterbau ist [termisu](https://github.com/omarluq/termisu): gemessen bester Byte-Verbrauch
pro Frame, 0,97 MB Binary, Sekunden Build-Zeit, und es liefert die fehleranfälligsten
Teile fertig (Key-Parsing, Unicode-Breiten, Cell-Diff, Raw-Mode-Details).

## Name

`anvil`. Der Schmied arbeitet am Amboss — der Name paart sich mit `smith` und beschreibt
zugleich, was die Library ist: die Fläche, auf der geformt wird (`Anvil::Surface`).
Im Crystal-Ökosystem frei; der bisherige Arbeitsname `crystal_tui` war durch
`skuznetsov/crystal_tui` belegt. Der Repo-Name bleibt `crystal_tui`.

## Architektur

```
                    termisu
   Raw-Mode · Key-Parsing · Größe · Cell-Buffer+Diff · Unicode-Breiten
                       │
        ┌──────────────┴───────────────┐
        │      Anvil::Surface          │   ← der eine Seam, der die Modi trennt
        ├──────────────┬───────────────┤
        │  Fullscreen  │    Inline     │
        │  (Alt-Screen)│ (Live-Region) │
        └──────────────┴───────────────┘
                       │
   Anvil::Text     Style · Span · StyledLine · wrap · truncate · Palette
                       │
   Anvil::View     Block · Region-Komposition mit Drop-Priorität
                       │
   Anvil::App      Loop · Zustandsmaschine · Modals · Resize-Debounce · Signale
                       │
   Anvil::Widgets  InputEditor · ListPopup · StatusBar
```

Nur `Surface` kennt den Unterschied zwischen den Modi. Alles darüber ist gemeinsam —
das ist der Punkt, an dem sich die Library für beide Projektarten rentiert.

## Die zwei Surfaces

Gemeinsames Protokoll:

```crystal
abstract class Anvil::Surface
  abstract def size : {Int32, Int32}
  abstract def begin_frame : Nil
  abstract def put(x : Int32, y : Int32, line : Text::StyledLine) : Nil
  abstract def end_frame : Nil          # ein Flush, Synchronized Output
  abstract def invalidate! : Nil        # nächster Frame ist ein Vollaufbau
  abstract def cursor(x : Int32, y : Int32) : Nil
end
```

**Fullscreen** ist dünn: `Termisu.new`, `set_cell`, `render`. Die Benchmark-Zahlen gelten
unverändert.

**Inline** ist der Eigenanteil. termisus Fassade betritt im Konstruktor bedingungslos den
Alt-Screen — aber `Termisu::Terminal`, `Reader`, `Input::Parser`, `Event::Loop` und die
`Event::Source::*` sind alle öffentlich. Der Stack wird also von Hand zusammengesetzt,
genau wie `Termisu#initialize` es tut, nur ohne `enter_alternate_screen`. **Verifiziert.**

Für das Zeichnen der Region: `Termisu::Terminal < Termisu::Renderer`, und
`Buffer#render_to(renderer)` nimmt jede `Renderer`-Implementierung. Ein
`Anvil::InlineRenderer` delegiert alles an das echte Terminal und übersetzt nur
`move_cursor(x, y)` in relative Bewegungen innerhalb der Region — die Schnittstelle
reicht `columns_advanced` durch jede `write`, das Cursor-Tracking ist also vorgesehen.

Damit erbt der Inline-Modus termisus Cell-Diff, SGR-Coalescing und Wide-Char-Logik,
statt sie nachzubauen.

> **Korrektur zu SMITH-REQUIREMENTS.md:** dort steht, ein Zeilen-Diff sei die Alternative.
> Ist er — aber er verschenkt genau die getesteten Teile, für die termisu ausgewählt
> wurde. Der `InlineRenderer` ist der bessere Weg. Falls die relative Adressierung sich
> als zäh erweist, ist der Zeilen-Diff (~60 Zeilen) der dokumentierte Rückfall.
> **Schritt 1 des Plans ist genau dieser Test**, bevor Arbeit darauf aufbaut.

Regeln, die der Inline-Modus einhalten muss (alle aus smiths Erfahrung):

1. **Eine Regionszeile = genau eine Terminalzeile.** Umbrüche passieren beim Komponieren,
   nicht beim Schreiben — sonst geht das Aufräumen der alten Region gegen den Bildschirm
   aus dem Takt.
2. **Regionshöhe ist variabel.** Wächst sie, werden Zeilen per `\n` angefordert (das
   Terminal scrollt); schrumpft sie, werden die überzähligen gelöscht.
3. **Commit in den Scrollback:** Region abräumen → fertige Blöcke mit `\n` ausgeben →
   Region darunter neu aufbauen. Danach `invalidate!`, denn der Bildschirm hat sich
   unter dem Front-Buffer verschoben.
4. **Fremdausgabe korrumpiert den Bildschirm.** Ein Subprozess, der nach STDOUT schreibt,
   macht den Front-Buffer ungültig. Die Library liefert dafür ein `CaptureIO`, das
   solche Schreibvorgänge in Notice-Blöcke umleitet (smith hat das als `NoticeIO`), plus
   `invalidate!` als Notausgang für Ctrl-L.

## Module und Umfang

| Modul | Inhalt | geschätzt |
|---|---|---|
| `Anvil::Text` | `Style` (merge, ANSI), `Span`, `StyledLine`, `wrap` über Span-Grenzen, `truncate`, `Palette`; Breiten aus termisus `unicode_width` | ~320 |
| `Anvil::Surface` | Protokoll + `Fullscreen` + `Inline` + `InlineRenderer` | ~380 |
| `Anvil::View` | `Block`-Protokoll (`lines(width)`, `finalized?`), Region-Komposition mit Drop-Priorität (auf zu kleinem Schirm fällt Unwichtiges zuerst) | ~180 |
| `Anvil::App` | Loop, Dirty-Flag, Zustandsmaschine, `Channel`-Modals, `modal_sync`, Resize-Debounce, Signal-Restore, Ctrl-L, doppeltes Ctrl-C | ~420 |
| `Anvil::Widgets` | `InputEditor` (History, Ctrl-A/E/B/F/U/K/W, Paste-Flattening, horizontaler Scroll), `ListPopup` (Filter, Auswahl, Fenster), `StatusBar` | ~330 |
| `Anvil::Markdown` | optional, Markdown → `StyledLine` | ~230 |

Rund 1 600 Zeilen ohne Markdown. Ersetzt bei smith ~1 790.

## Bauabschnitte

Jeder Abschnitt endet lauffähig und überprüfbar.

### 1. Spike: InlineRenderer ✅ erledigt
termisu-Stack ohne Alt-Screen zusammensetzen, `Buffer` in eine 5-zeilige Region am
unteren Rand rendern, Region wachsen/schrumpfen lassen, Text in den Scrollback
committen.
*Ergebnis:* trägt. `Anvil::InlineRenderer` (~90 Zeilen) zeichnet über termisus
`Buffer`, adressiert vertikal relativ (CUU/CUD) und horizontal absolut (CHA, weil die
Region immer in Spalte 0 beginnt — das spart die gesamte Spaltenbuchhaltung).
`examples/check_inline.py` prüft headless: kein Alt-Screen, kein Vollbild-Clear, Scrollback
vollständig und in Reihenfolge, 0 absolute Cursorpositionierungen. Im echten Terminal
bestätigt: Wachsen 3→6, Schrumpfen 6→2 und drei Commits ohne Reste und ohne Flackern.
Der Zeilen-Diff als Rückfall wird nicht gebraucht.

### 2. `Anvil::Text` ✅ erledigt
Reine Datenschicht, komplett gegen `IO::Memory` testbar. `wrap` ist der heikle Teil:
Umbruch über Span-Grenzen unter Erhalt der Styles, mit CJK- und Emoji-Breiten.
*Ergebnis:* `src/anvil/text.cr`, 19 Specs grün (`spec/text_spec.cr`). Breiten kommen aus
`Termisu::UnicodeWidth` statt aus einer zweiten Implementierung — was hier als 79 Spalten
gilt, muss dort in 79 Zellen passen. `wrap` bricht über Span-Grenzen hinweg, trennt zu
lange Wörter hart (die Zusage „keine Zeile ist breiter als `width`" trägt die Höhen-
rechnung der Inline-Region), rechnet mit CJK- und Emoji-Breiten und fasst gleich
gestylte Grapheme zu einem Span zusammen, damit der Renderer Batches statt Einzelzellen
bekommt.

### 3. `Anvil::Surface` ✅ erledigt
*Ergebnis:* `Anvil::Backend` (Terminal, Eingabe, Ereignisschleife — gemeinsam für beide
Betriebsarten, mit dem Alt-Screen als Schalter), `Anvil::Surface` als Protokoll,
`Surface::Fullscreen` und `Surface::Inline`.

Der Benchmark ist jetzt Regressionstest (`bin/anvil`, 300 Frames, 200×50, 60 fps):

| | churn p50 | churn B/Frame | dashboard p50 | dashboard B/Frame |
|---|---:|---:|---:|---:|
| termisu direkt | 4,36 ms | 312 580 | 2,29 ms | 6 835 |
| durch die Surface | 4,42 ms | **312 581** | 1,63 ms | 6 836 |

Die Abstraktion kostet nichts: byte-identisch bis auf die Stelle, an der die
Frame-Nummer eine Ziffer mehr hat. Die bessere Frame-Zeit im Dashboard-Fall kommt nicht
von der Surface, sondern vom Fixed-Timestep-Loop des Benchmarks gegenüber termisus
Tick-Schleife — er trifft auch die Cadence besser (59,9 statt 57,8 fps), was die
gemessene Timer-Drift bestätigt.

Die Inline-Surface besteht dieselben Prüfungen wie der Spike, jetzt gegen den
Produktionscode (`examples/inline_demo.cr`, `examples/check_inline.py`): kein Alt-Screen, kein
Vollbild-Clear, Scrollback vollständig, 0 absolute Cursorpositionierungen.

Das Signal-Handling im `Backend` schließt die im Benchmark gemessene termisu-Lücke —
`bench/restore_check.py` bei SIGINT:

| | Alt-Screen verlassen | Cursor sichtbar |
|---|---|---|
| termisu direkt | nein | nein |
| durch `Anvil::Backend` | **ja** | **ja** |

### 4. `Anvil::View` + `Anvil::Widgets` ✅ erledigt
*Ergebnis:* `View::Block`/`TextBlock`, `View::Segment`/`Region.compose`,
`Widgets::InputEditor`, `Widgets::ListPopup(T)`. 48 Specs grün, alle ohne Terminal —
Tastenereignisse werden in `spec/spec_helper.cr` direkt gebaut.

Zwei Dinge aus smiths Code übernommen, die man sonst erst durch Schaden lernt:

- **Die Region darf nie höher als der Bildschirm werden.** `cursor_up` stoppt an der
  obersten Zeile, eine höhere Region ließe sich nie zurücklaufen — jeder Redraw schöbe
  eine weitere Kopie in den Scrollback. `Surface::Inline#max_height` deckelt das jetzt,
  `Region.compose` wirft nicht-angeheftete Zeilen weg (älteste zuerst, hinter einer
  Marke), und angeheftete — Statusleiste, Eingabezeile — bleiben immer.
- **Bracketed Paste gehört eingeschaltet** (`\e[?2004h` im `Backend`). Ohne das ist
  eingefügter Text nicht von getipptem zu unterscheiden, und mehrzeiliges Einfügen löst
  pro Zeile ein Absenden aus. Der Editor behandelt `PasteStart`/`PasteEnd` und glättet
  Umbrüche zu Leerzeichen.

### 5. `Anvil::App` ✅ erledigt
*Ergebnis:* `Anvil::Loop` (Takt, Drift-Korrektur, Resize-Entprellung) getrennt von
`Anvil::App` (Blöcke, Live-Region, Modals, Zustandsmaschine) — so kann eine
Vollbild-Anwendung die Schleife ohne die Block-Maschinerie nutzen.

Zwei Nähte für die Testbarkeit, die die Architektur nebenbei verbessert haben:
`Loop` nimmt die Ereignisquelle als `Proc` statt als `Backend`, und `Surface::Memory`
ist eine Zeichenfläche im Speicher. Dadurch läuft `App` gegen `Surface` statt gegen
`Surface::Inline`, und die Specs brauchen kein Terminal.

**Ein echter Fehler, den die Specs aufgedeckt haben:** der Parser liefert Ctrl-Tasten als
Key-Enum mit leerem `char` (Ctrl-A ist `Key::LowerA` plus Modifier). Der erste Entwurf
las `event.char` und hätte am echten Terminal *keine* Ctrl-Taste getroffen — weder
Ctrl-L noch die Editor-Kürzel. Der Spec-Helfer bildet das Verhalten des Parsers jetzt
genau nach, statt ein `char` mitzugeben und den Fehler zu verdecken.

68 Specs grün. `bench/restore_check.py` bestätigt sauberes Aufräumen bei normalem Ende
und bei SIGINT; `examples/check_demo.py` fährt eine vollständige Sitzung durch ein PTY
(tippen, streamen, modale Rückfrage beantworten, beenden) und prüft zehn Eigenschaften
der Ausgabe.

### 6. Inline-Szenario im Benchmark ✅ erledigt
*Ergebnis:* `bench/inline_bench.cr`, 300 Frames bei 60 fps, 200 Spalten:

| Region | geänderte Zeilen | Bytes/Redraw | p50 | CPU |
|---:|---:|---:|---:|---:|
| 15 | 2 | **118** | 0,082 ms | 1,5 % |
| 20 | 4 | 198 | 0,111 ms | 1,8 % |
| 40 | 2 | 137 | 0,188 ms | 2,6 % |

Zum Vergleich das Vollbild-Dashboard auf 200×50: 6 836 Bytes pro Frame.

Der Befund dahinter ist wichtiger als die absoluten Zahlen: **die Regionshöhe kostet
fast nichts, nur Veränderung kostet.** Eine Region von 40 Zeilen mit zwei bewegten
kostet 137 Bytes, eine von 15 Zeilen mit denselben zwei kostet 118. Der Diff arbeitet,
und eine Inline-App ist damit selbst bei 60 fps rund zwei Größenordnungen günstiger als
ein Vollbild-Redraw.

## smith-Migration in zwei Phasen

**Phase A — ohne Rendering-Änderung.** smith ersetzt `style.cr`, `input_editor.cr`,
`completions.cr` durch die Library, behält aber `terminal.cr` und `app.cr`. Reine
Datenschichten, geringes Risiko, smith bleibt jederzeit lauffähig. Prüfung: bestehende
Specs plus Sichtvergleich.

**Phase B — die Schleife.** `terminal.cr` und der Großteil von `app.cr` weichen
`Anvil::App` mit `Surface::Inline`. In smith bleibt, was Domäne ist: `renderer.cr`,
`gates.cr`, die konkreten Block-Typen, der Inhalt der Statusleiste.

Getrennte Phasen, weil Phase B die riskante ist — eine kaputte Eingabeschleife macht das
Werkzeug unbenutzbar, und Phase A stellt vorher sicher, dass die Datenschichten stimmen.

## Teststrategie

- **Datenschichten** (`Text`, `View`, `Widgets`) gegen `IO::Memory` — kein Terminal nötig.
  smith hat seinen `KeyParser` genau dafür herausgezogen; das Muster wird beibehalten.
- **Surfaces** gegen eine `Renderer`-Implementierung, die in einen String schreibt: Specs
  behaupten über die erzeugte Byte-Folge, nicht über Pixel.
- **End-to-End** über `bench/pty_run.py` (echtes PTY fester Größe) und
  `bench/restore_check.py` (Aufräumen bei Signal).
- **Performance** über `bench/run.sh` gegen `bin/baseline` als Regressionsschwelle.

## Was bewusst nicht hineinkommt

Kein CSS, keine Layout-Engine, kein Widget-Zoo. Das ist genau der Weg, auf dem crysterm
bei 98 000 LOC und 35 MB Binary gelandet ist. Layout bleibt beim Aufrufer: eine
`StyledLine`-Liste und die Regeln, was auf einem kleinen Schirm zuerst verschwindet.
