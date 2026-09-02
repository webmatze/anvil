# Benchmark: Womit baut man in Crystal eine flickerfreie Fullscreen-TUI?

Gemessen auf macOS (Apple Silicon), Crystal 1.21.0, Release-Builds, 200×50 Zellen,
TrueColor, 600 Frames pro Lauf, headless über ein PTY fester Größe.

Priorisierte Kriterien: **flickerfreies Rendering** und **kleine Binaries**.
Absolute Framerate ist nachrangig, solange 30–60 fps sicher gehalten werden.

## Empfehlung

**Eine dünne eigene Schicht auf [termisu](https://github.com/omarluq/termisu).**

termisu ist bei den Bytes pro Frame in beiden Szenarien der beste Kandidat — und
das ist unter Synchronized Output die Größe, die über Flickern entscheidet. Es kostet
0,97 MB Binary gegenüber 0,60 MB für handgeschriebenen Code, und liefert dafür den
kompletten Input-Stack, Wide-Char-Handling und einen Tick-Timer. Was du selbst
ergänzen musst, ist überschaubar und in `bench/baseline.cr` bereits vorexerziert:
ein Fixed-Timestep-Loop mit Drift-Korrektur und ein Signal-Handler fürs Terminal-Restore.

Gegen die Alternativen:

- **crysterm** ist raus, obwohl es technisch am meisten kann: 35 MB Binary (59× termisu),
  ~25 Minuten Release-Build, und es hält die angeforderte Framerate nicht ein.
- **sk_tui** ist überraschend klein (0,68 MB), verbraucht aber 74 % mehr Bytes pro Frame
  als termisu — genau die falsche Richtung für dein Hauptkriterium.
- **From scratch** ist verteidigbar (0,60 MB, exakte Cadence, null Fremdabhängigkeit),
  aber der Aufpreis von 0,37 MB kauft dir bei termisu Input-Parsing, Bracketed Paste,
  Grapheme-Cluster und Wide-Char-Behandlung — alles Dinge, die einzeln klein aussehen
  und in der Summe wochenlang Detailarbeit sind.

## Flickern

Alle vier Implementierungen verhalten sich hier grundsätzlich korrekt:

| Impl | Sync-Marker pro Frame | Vollbild-Löschungen im Betrieb | Cursor versteckt |
|---|---:|---:|---|
| baseline | 120/120 | 0 | ja |
| termisu | 120/120 | 0 | ja |
| sk_tui | 120/120 | 0 | ja |
| crysterm | 120/120 | 0 | ja |

Jede umschließt jeden Frame mit DEC 2026 Synchronized Output (`ESC[?2026h/l`) und löscht
im laufenden Betrieb nie den Bildschirm. Auf Ghostty, das DEC 2026 unterstützt, sollte
daher keine davon reißen.

Damit verschiebt sich die Flicker-Frage auf zwei andere Größen:

**1. Bytes pro Frame.** Unter Synchronized Output hält das Terminal den Frame zurück, bis
die Endmarke kommt — je größer der Frame, desto länger dieses Fenster. Bei 331 KB/Frame
(Vollbild-Churn) sind das bei 60 fps 20 MB/s, mehr als ein Terminal aufnimmt; die
effektive Bildrate bricht dann ein, egal was die App tut. Im realistischen Dashboard-Fall:

| Impl | Bytes/Frame | pro geänderter Zelle |
|---|---:|---:|
| baseline | 6 785 | 17,2 |
| **termisu** | **6 795** | **17,3** |
| crysterm | 8 891 | 22,6 |
| sk_tui | 11 833 | 30,1 |

**2. Gleichmäßigkeit der Cadence.** Ein Frame, der mal 16 und mal 27 ms braucht, wirkt
unruhig, auch wenn der Durchschnitt stimmt. Angefordert vs. erreicht (Dashboard):

| Impl | Ziel 30 | Ziel 60 |
|---|---:|---:|
| baseline (fixed timestep) | 30,0 | 60,0 |
| termisu (sleep-Timer) | 29,6 | 58,2 |
| termisu (Kernel-Timer, kqueue) | 30,3 | 62,4 |
| sk_tui (eigener Loop wie baseline) | 30,0 | 60,0 |
| **crysterm** | **50,3** | **52,7** |

crysterm ignoriert die Taktvorgabe: Sein Render-Loop koalesziert Frames nach eigener
Logik und rendert bei Ziel 30 zu viel, bei Ziel 60 zu wenig. termisus beide Timer laufen
um 3–4 % daneben und brauchen in einer Library-Schicht eine Drift-Korrektur — der
Fixed-Timestep-Loop der Baseline (`bench/baseline.cr`, `next_at += interval`) trifft
die Vorgabe exakt und ist ~10 Zeilen.

Was diese Messung *nicht* zeigt: wie es real aussieht. Das PTY im Testaufbau wird von
einem Reader geleert, der nichts zeichnet — ein echtes Terminal ist langsamer. Für
Tearing und gefühlte Ruhe: `bench/interactive.sh <impl> <szenario> <fps>` in Ghostty.

## Interaktive Bestätigung (Ghostty, echtes Terminal)

Beide Szenarien, 95×28 Zellen, 600 Frames:

| | `dashboard` | `churn` |
|---|---|---|
| erreicht | 58,3 fps (Ziel 60) | 58,1 fps (Ziel 60) |
| Frame-Zeit p50 | 1,08 ms | 3,05 ms |
| p95 / p99 | 1,66 / 2,08 ms | 4,86 / 5,77 ms |
| verpasste Ticks | 0 | 0 |
| Bytes/Frame (gerechnet) | ~1,6 KB | ~83 KB |
| Tearing | keins | keins |
| Terminal danach | sauber wiederhergestellt | sauber wiederhergestellt |

Deckt sich mit der Headless-Messung: die Frame-Zeit skaliert mit der Zellenzahl
(95×28 ≈ 2 660 Zellen gegenüber 10 000 im Testraster), und der Sleep-Timer läuft auch
im echten Terminal 3 % zu langsam — die Drift-Korrektur ist also real nötig, nicht ein
Artefakt des Messaufbaus.

Der Churn-Fall ist die Belastungsprobe: jede Zelle ändert sich jeden Frame, ~83 KB/Frame
bzw. ~4,8 MB/s. Ghostty verarbeitet das ohne sichtbares Reißen und ohne einen einzigen
verpassten Tick — bei p99 von 5,8 ms bleiben über 10 ms Puffer im 16-ms-Budget.

**Wichtig für die Skalierung:** dieser Puffer hängt an der Fenstergröße. Dasselbe
Szenario auf 200×50 sind 313 KB/Frame, bei 60 fps also 18 MB/s — dort bricht die
Bildrate ein, unabhängig von der Library. Ein Vollbild-Effekt, bei dem sich wirklich
jede Zelle ändert, ist auf großen Terminals nicht bei 60 fps zu haben; alles, was
weniger als ~5 % der Zellen pro Frame anfasst, ist dagegen weit im grünen Bereich.

## Binary-Größe

Gleiche App (Vollbild-Renderer, beide Szenarien), Release-Build, gestrippt:

| Impl | Binary | vs. baseline |
|---|---:|---:|
| baseline (ohne Library) | 0,60 MB | 1,0× |
| sk_tui | 0,68 MB | 1,1× |
| termisu | 0,97 MB | 1,6× |
| crysterm | 35,36 MB | 59× |

Minimal-App, die die Library nur einbindet: baseline 0,44 MB · sk_tui 0,51 MB ·
termisu 0,86 MB.

Crystal generiert nur erreichbaren Code — deshalb kostet sk_tuis Widget- und CSS-Schicht
nichts, solange sie ungenutzt bleibt, obwohl die Library 29 000 LOC hat. Bei crysterm
greift das nicht: schon eine einzelne `Box` mit Paint-Handler zieht 35 MB nach sich, weil
CSS-Engine, 12 Layout-Engines und die Medien-Backends unbedingt mitkommen.

## Vollständige Messmatrix


### Szenario `churn` — 10000 geänderte Zellen/Frame

| Impl | Variante | Ziel | Erreicht fps | p50 ms | p95 ms | p99 ms | Bytes/Frame | B/Zelle | CPU % | Missed |
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

### Szenario `dashboard` — 394 geänderte Zellen/Frame

| Impl | Variante | Ziel | Erreicht fps | p50 ms | p95 ms | p99 ms | Bytes/Frame | B/Zelle | CPU % | Missed |
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

## Weitere Beobachtungen, die in die Entscheidung eingeflossen sind

**Signal-Handling.** termisu trappt nur `WINCH` — kein `INT`, kein `TERM`, kein
`at_exit`-Restore. Direkt nachgemessen (`bench/restore_check.py`): ein Signal hinterlässt
Raw-Mode und Alt-Screen, der Cursor bleibt unsichtbar. Normales Programmende stellt
sauber wieder her. sk_tui trappt `INT` und `TERM` (Code gelesen, nicht gemessen — der
Benchmark umgeht sein `Terminal.init`), crysterm hat ein vollständiges
`at_exit`-Restore-Netz. **Für eine Library auf termisu ist das die erste Lücke, die du
schließen musst.**

**Build-Zeit.** termisu und sk_tui bauen im Release in Sekunden, crysterm in ~25 Minuten
(Debug: 28 s). Bei iterativer CLI-Entwicklung ist das ein täglich spürbarer Preis.

**Reifegrad und Wartung.** crysterm ist bei 1.0.0 und aktiv (149★). termisu ist erklärt
pre-1.0 und „not battle tested", aber sehr aktiv und sichtbar sorgfältig gebaut — der
Cell-Buffer nutzt einen gepackten `UInt128`-Identitätsschlüssel, Dirty-Ranges pro Zeile
und interned Graphemes. sk_tui ist jung, aber täglich in Bewegung; im Hot Path
(`Buffer#set`) stehen allerdings zwei `ENV[]`-Lookups pro Zellschreibvorgang und ein
`Set(Tuple(Int32,Int32))` als Dirty-Tracking, und `#flush` baut jeden Frame per
`String.build` neu auf — das erklärt seinen Byte- und CPU-Mehrverbrauch.

**Korrektur zur Vorab-Recherche.** sk_tui hat entgegen seiner Dokumentation sehr wohl
einen Front/Back-Diff-Renderer (`Tui::Buffer#flush`); es wurde deshalb mitgemessen statt
ausgeschlossen. crysterm ist inzwischen 1.0.0 und installiert auf macOS ohne Handarbeit —
`unibilium` und `gpm` machen keine Probleme.

## Methodische Einschränkungen

- Widget- und Layout-Ebenen von crysterm und sk_tui werden bewusst umgangen; gemessen ist
  der Renderer, nicht der Szenegraph. Eine App, die deren Widgets nutzt, ist langsamer
  und größer als hier ausgewiesen.
- Das PTY wird von einem Reader geleert, der nichts zeichnet. Die Zahlen sind damit eine
  Obergrenze des Durchsatzes, kein Abbild eines echten Terminals.
- `chunks_per_frame` in `flicker_check.py` misst die PTY-Puffergröße (~1 KB), nicht die
  Schreib-Granularität der App — als Tearing-Metrik unbrauchbar, nur als Plausibilitäts-
  Check behalten.
- crysterms Frame-Zählung stützt sich auf `PreRender`/`Rendered`; da sein Loop selbst
  koalesziert, sind seine Frames nicht 1:1 die angeforderten Ticks.
