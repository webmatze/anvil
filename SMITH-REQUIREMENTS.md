# Was die Library mindestens können muss, um smith zu tragen

Analyse von `webmatze/smith` v0.3.0 (16 602 LOC gesamt, davon 2 687 in `src/smith/ui/`).

## Der Befund, der den Zuschnitt ändert

**smith ist keine Alt-Screen-App.** Aus dem eigenen Kommentar in `src/smith/ui/app.cr:15`:

> Rendering model (same as Claude Code): finished blocks are flushed into the normal
> scrollback once; the live region at the bottom — streaming text, running tools, status
> bar, input — is redrawn in place every tick. No alternate screen, so the transcript
> stays in the terminal's scrollback and can be copied and searched like any other output.

Das ist ein grundlegend anderes Modell als das, was der Benchmark gemessen hat. Konkret:

| | Fullscreen (Benchmark) | Inline (smith) |
|---|---|---|
| Bildschirm | Alt-Screen, App besitzt das ganze Raster | normaler Scrollback |
| Adressierung | absolute Zeilen `ESC[y;xH` | relativ, `ESC[nA` + `ESC[2K` ab Cursor |
| Zustand | ein Cell-Buffer über die volle Höhe | fertige Blöcke wandern in die History, nur die unteren *n* Zeilen sind lebendig |
| Höhe | fix (Terminalhöhe) | variabel, ändert sich mit dem Inhalt jeden Frame |
| Scrollback | keins (Alt-Screen) | ist das Feature |

**termisu kann diesen Modus nicht.** `Termisu.new` betritt bedingungslos den Alt-Screen
(`lib/termisu/src/termisu.cr:71`), und `Buffer#render_to` adressiert Zeilen absolut ab 0.

Die gute Nachricht: `Termisu::Renderer` ist eine saubere abstrakte Klasse, und
`Buffer#render_to(renderer)` nimmt jede Implementierung davon. Der Inline-Modus ist also
**ein eigener Renderer**, der `move_cursor(x, y)` auf relative Bewegungen innerhalb einer
am unteren Rand verankerten Region übersetzt — nicht ein Fork von termisu. Das ist der
wichtigste Einzelbaustein der Library.

## Mindest-Inventar

### 1. Backend / Terminal
| Element | Woher |
|---|---|
| Raw-Mode ohne `ISIG`/`ICRNL` (Ctrl-C als Taste, Enter ≠ Ctrl-J) | **termisu** ✓ (`termios.cr`, korrekt gelöst) |
| Größe per `TIOCGWINSZ`, Fallback `COLUMNS`/`LINES` | **termisu** ✓ (Fallback fehlt, ~5 Zeilen) |
| Bracketed Paste | **termisu** ✓ |
| Alt-Screen betreten/verlassen | **termisu** ✓ |
| **Terminal-Restore bei `INT`/`TERM` + `at_exit`** | **wir** — termisu trappt nur `WINCH`; smith macht das heute selbst (`terminal.cr:322`) |

### 2. Zwei Render-Modi
| Element | Woher |
|---|---|
| Cell-Buffer mit Diff, Wide-Chars, Grapheme-Cluster | **termisu** ✓ |
| Synchronized Output (DEC 2026) | **termisu** ✓ |
| Fullscreen-Modus (Alt-Screen, absolutes Raster) | **termisu** ✓ |
| **Inline-Modus: `Renderer`-Implementierung mit relativer Adressierung** | **wir** — der Kern |
| **Live-Region mit variabler Höhe** (`clear_drawn!` / `draw!`-Zyklus) | **wir** — smith: `app.cr:529` |
| **Commit von fertigem Inhalt in den Scrollback** (einmalig, nie neu gezeichnet) | **wir** — smith: `flush_blocks!` |
| **Voller Neuaufbau auf Anforderung** (Ctrl-L, nach Resize) | **wir** — smith: `redraw_all!` |

### 3. Styled-Text-Schicht
termisu ist ein *Cell*-Buffer und kennt keine Zeilen, Spans oder Umbrüche. smith hat das
komplett selbst gebaut (`style.cr`, 263 LOC) — das gehört in die Library:

| Element | Woher |
|---|---|
| `Style` (fg 256-Farben, bold, dim, italic, underline) mit `merge` | **wir** (termisu hat `Color`/`Attribute` als Bausteine) |
| `Span` = Text + Style, `StyledLine` = `Array(Span)` | **wir** |
| `display_width` / `char_width` inkl. CJK und Emoji | **termisu** ✓ (`unicode_width.cr`) — smiths eigene Implementierung entfällt |
| **`wrap(line, width)`** — Umbruch über Span-Grenzen hinweg | **wir** |
| **`truncate(line, width, ellipsis)`** | **wir** |
| Rendern einer `StyledLine` in den Cell-Buffer *und* als ANSI-String | **wir** |
| Palette (benannte Farbrollen statt Zahlen) | **wir** |

### 4. Block-/Inhaltsmodell
| Element | Woher |
|---|---|
| `Block`-Basis: `lines(width) : Array(StyledLine)` + `finalized?` | **wir** — generisch |
| Lebenszyklus live → finalisiert → in Scrollback committed | **wir** |
| Konkrete Blöcke (Assistant, Tool, Todos, Thinking, Notice) | **bleibt in smith** — Domäne |
| Markdown → `StyledLine` (`markdown.cr`, 232 LOC) | **optional Library** — generisch genug, aber kein Muss für v1 |

### 5. Eingabe
| Element | Woher |
|---|---|
| Key-Parsing inkl. CSI, SS3, UTF-8, Alt+Taste | **termisu** ✓ — deckt smiths `KeyParser` (215 LOC) vollständig ab |
| Home/End/Delete/PageUp/F1–F24 | **termisu** ✓ |
| `Tick`-Event bei Leerlauf (Poll-Fenster ohne Eingabe) | **termisu** ✓ (Timer-Source) |
| Resize-Event | **termisu** ✓ |
| **Zeileneditor**: Cursor, History (↑/↓), Ctrl-A/E/B/F/U/K/W, Paste-Flattening | **wir** — smith: `input_editor.cr`, 169 LOC |
| **Filter-Popup** (Slash-Command-Palette: Query, Auswahl, Fenster) | **wir** — smith: `completions.cr`, 88 LOC, generisch als Listen-Popup |

### 6. App-Schleife
| Element | Woher |
|---|---|
| Event-Loop mit Timeout-Poll | **termisu** ✓ |
| **Fixed-Timestep mit Drift-Korrektur** | **wir** — im Benchmark bestätigt: termisus Timer laufen 3–4 % daneben |
| **Dirty-Flag statt bedingungslosem Redraw** | **wir** — smith: `mark_dirty` / `needs_draw?` |
| **Resize-Debounce** (Fensterziehen liefert ein `WINCH` pro Pixelschritt; smith wartet 3 ruhige Poll-Fenster ab, sonst flackert es) | **wir** — `RESIZE_SETTLE_TICKS`, `app.cr:71` |
| **Zustandsmaschine** Idle / Busy / ModalChar / ModalText / Done | **wir** |
| **Modale Abfrage über `Channel`**, die einen *anderen* Fiber blockiert, während der Key-Loop weiterläuft | **wir** — `app.cr:148`; für Tool-Approval, Plan-Gate, Trust-Prompt unverzichtbar |
| **Synchroner Modal-Modus** vor dem Start der Hauptschleife (`modal_sync`) | **wir** — smith braucht das für den Trust-Prompt |
| Ctrl-L (Neuaufbau), doppeltes Ctrl-C (Interrupt → Abbruch) | **wir** |
| Cursor-Platzierung in der Eingabezeile inkl. horizontalem Scroll | **wir** |

## Was das für smith konkret heißt

Ersetzbar durch die Library: **~1 790 LOC** von smiths 2 687 UI-Zeilen —
`terminal.cr` (403), `style.cr` (263), `input_editor.cr` (169), `completions.cr` (88)
und der Großteil von `app.cr` (868). Mit `markdown.cr` wären es ~2 020.

Bleibt in smith: `renderer.cr` (Event-Stream → Blöcke), `gates.cr` (Approver, Plan-Gate,
Trust-Prompt), `presentation.cr`, die konkreten Block-Typen aus `view_model.cr` und der
Inhalt der Statusleiste. Alles Domäne, nichts davon gehört in eine TUI-Library.

## Konsequenz für die Library-Planung

1. **Der Inline-Modus ist kein Nachzügler, sondern gleichrangig.** Wenn smith das
   Integrationsziel ist, muss er in v1 — sonst trägt die Library das Projekt nicht.
   Ein reiner Fullscreen-Wrapper um termisu wäre für smith wertlos.
2. **Der Benchmark hat den falschen Modus vermessen.** Die Zahlen gelten weiter für
   Fullscreen-Apps; für smiths Inline-Modell ist die relevante Größe nicht
   „Bytes pro Vollbild-Frame", sondern „Bytes pro Redraw der Live-Region" (bei smith
   typisch 10–20 Zeilen). `bench/` sollte um ein Inline-Szenario ergänzt werden, sobald
   der Renderer steht.
3. **Die Styled-Text-Schicht ist der größte Eigenanteil** und in termisu gar nicht
   vorhanden. Sie ist auch das, was smith heute am meisten Code kostet.
4. **termisus Beitrag bleibt trotzdem substanziell**: Key-Parsing, Unicode-Breiten,
   Cell-Diff, Raw-Mode-Details, Bracketed Paste — zusammen der fehleranfälligste Teil.
