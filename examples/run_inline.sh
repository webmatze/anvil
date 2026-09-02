#!/usr/bin/env bash
# Inline-Spike im echten Terminal. Danach muss der Scrollback oberhalb
# vollständig lesbar sein — genau das kann die Headless-Prüfung nicht zeigen.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -x bin/inline_demo ] || crystal build examples/inline_demo.cr -o bin/inline_demo

SPIKE_FRAMES="${1:-12}" SPIKE_DELAY_MS="${2:-120}" ./bin/inline_demo

cat <<'CHECK'

Checkliste:
  - Sind "Scrollback-Zeile A/B" und alle drei "committed"-Zeilen noch da,
    in dieser Reihenfolge, oberhalb dieser Ausgabe?
  - Hat die Region beim Wachsen (3→6) und Schrumpfen (6→2) sauber gezeichnet,
    ohne Reste der vorigen Höhe?
  - Flackerte etwas, oder sprang der Cursor sichtbar?
  - Kannst du hochscrollen und alles lesen?
CHECK
