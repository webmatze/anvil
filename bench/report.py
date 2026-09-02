#!/usr/bin/env python3
"""Renders bench/results/raw.jsonl as Markdown tables."""
import json, sys, collections

rows = []
with open("bench/results/raw.jsonl") as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))

# The scenario decides how many cells actually change; the baseline measures
# it directly and every implementation paints identical content, so its count
# is the ground truth for all of them.
changed = {}
for r in rows:
    if r.get("cells_changed_per_frame"):
        changed[r["scenario"]] = r["cells_changed_per_frame"]

def fmt(v, spec=".1f"):
    if v is None: return "-"
    if isinstance(v, str): return v
    return format(v, spec)

for scenario in ("churn", "dashboard"):
    sel = [r for r in rows if r.get("scenario") == scenario]
    if not sel: continue
    cc = changed.get(scenario)
    print(f"\n### Scenario `{scenario}`"
          + (f" — {cc:.0f} changed cells/frame" if cc else ""))
    print()
    print("| Impl | Variant | Target | Achieved fps | p50 ms | p95 ms | p99 ms | Bytes/frame | B/cell | CPU % | Missed |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in sorted(sel, key=lambda r: (r["target_fps"], r["impl"], r["variant"])):
        bpf = r.get("bytes_per_frame")
        bpc = (bpf / cc) if (bpf and cc) else None
        print("| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            r["impl"], r["variant"], r["target_fps"],
            fmt(r.get("achieved_fps")), fmt(r.get("frame_ms_p50"), ".2f"),
            fmt(r.get("frame_ms_p95"), ".2f"), fmt(r.get("frame_ms_p99"), ".2f"),
            f"{bpf:,.0f}".replace(",", " ") if bpf else "-",
            fmt(bpc, ".1f"), fmt(r.get("cpu_pct_of_wall")), r.get("missed_ticks", "-")))
