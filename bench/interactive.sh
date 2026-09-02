#!/usr/bin/env bash
# Runs one bench binary directly in YOUR terminal, so you can judge what the
# headless numbers cannot show: tearing, perceived smoothness, and whether the
# terminal is left intact afterwards.
#
#   bench/interactive.sh termisu churn 60 [frames] [variant]
set -euo pipefail
cd "$(dirname "$0")/.."

IMPL="${1:-termisu}"
SCENARIO="${2:-churn}"
FPS="${3:-60}"
FRAMES="${4:-600}"
VARIANT="${5:-default}"

[ -x "bin/$IMPL" ] || { echo "bin/$IMPL not built"; exit 1; }

BENCH_SCENARIO="$SCENARIO" BENCH_TARGET_FPS="$FPS" \
BENCH_FRAMES="$FRAMES" BENCH_VARIANT="$VARIANT" \
  "./bin/$IMPL" 2> >(tee /dev/stderr > "bench/results/interactive-$IMPL-$SCENARIO-$FPS.json")

echo
echo "Checkliste:"
echo "  - Tearing / halb gezeichnete Frames sichtbar?"
echo "  - Cursor wieder sichtbar, Prompt normal, kein Alt-Screen-Rest?"
echo "  - Terminal reagiert normal auf Eingabe (Raw-Mode zurückgesetzt)?"
