#!/usr/bin/env bash
# Runs the full benchmark matrix and appends one JSON line per run to
# bench/results/raw.jsonl.
set -uo pipefail
cd "$(dirname "$0")/.."

FRAMES="${FRAMES:-600}"
OUT=bench/results/raw.jsonl
mkdir -p bench/results
: > "$OUT"

run() { # impl variant scenario fps
  local impl="$1" variant="$2" scenario="$3" fps="$4"
  local bin="bin/$impl"
  [ -x "$bin" ] || { echo "skip: $bin not built" >&2; return; }
  echo "run: $impl/$variant $scenario @${fps}fps" >&2
  BENCH_SCENARIO="$scenario" BENCH_TARGET_FPS="$fps" \
  BENCH_FRAMES="$FRAMES" BENCH_VARIANT="$variant" \
    python3 bench/pty_run.py "$PWD/$bin" >> "$OUT"
}

for scenario in churn dashboard; do
  for fps in 30 60; do
    run anvil    default  "$scenario" "$fps"
    run baseline default  "$scenario" "$fps"
    run baseline nosync   "$scenario" "$fps"
    run termisu  default  "$scenario" "$fps"
    run termisu  systimer "$scenario" "$fps"
    run termisu  nosync   "$scenario" "$fps"
    run sk_tui   default  "$scenario" "$fps"
    run sk_tui   nosync   "$scenario" "$fps"
    run crysterm default  "$scenario" "$fps"
    run crysterm nosync   "$scenario" "$fps"
  done
done

echo "wrote $OUT ($(wc -l < "$OUT") runs)" >&2
