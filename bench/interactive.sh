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
echo "Checklist:"
echo "  - Any tearing or half-drawn frames?"
echo "  - Cursor visible again, prompt normal, no alternate-screen remains?"
echo "  - Does the terminal respond to input normally (raw mode reset)?"
