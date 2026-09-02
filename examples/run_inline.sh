#!/usr/bin/env bash
# Inline rendering in a real terminal. Afterwards the scrollback above must be
# readable in full — exactly what the headless check cannot show.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -x bin/inline_demo ] || crystal build examples/inline_demo.cr -o bin/inline_demo

SPIKE_FRAMES="${1:-12}" SPIKE_DELAY_MS="${2:-120}" ./bin/inline_demo

cat <<'CHECK'

Checklist:
  - Are "scrollback line A/B" and all three "committed" lines still there,
    in that order, above this output?
  - Did the region draw cleanly while growing (3→6) and shrinking (6→2),
    with no remains of the previous height?
  - Did anything flicker, or did the cursor visibly jump?
  - Can you scroll up and read all of it?
CHECK
