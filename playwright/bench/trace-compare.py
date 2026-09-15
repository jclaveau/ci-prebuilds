#!/usr/bin/env python3
"""Per-scenario, per-event self-time ratios alpine/official from two trace-probe.cjs outputs.

  python3 trace-compare.py <dir with alpine-trace.json + official-trace.json>
"""
import json, pathlib, sys
D=pathlib.Path(sys.argv[1])
a=json.loads((D/"alpine-trace.json").read_text()); o=json.loads((D/"official-trace.json").read_text())
for sc in a["scenarios"]:
    sa,so=a["scenarios"][sc],o["scenarios"][sc]
    print(f"== {sc}: wall {sa['wall_ms']:.0f} / {so['wall_ms']:.0f} = {sa['wall_ms']/so['wall_ms']:.2f}   events {sa['events']} / {so['events']}")
    names=set(sa["self_ms"])|set(so["self_ms"])
    rows=[(n,sa["self_ms"].get(n,0),so["self_ms"].get(n,0)) for n in names]
    rows=[r for r in rows if max(r[1],r[2])>=max(8, 0.01*max(sa['wall_ms'],so['wall_ms']))]
    rows.sort(key=lambda r:-(r[1]-r[2]))
    print(f"   {'event (self ms)':<48}{'alpine':>8}{'official':>9}{'ratio':>7}{'delta':>7}")
    for n,x,y in rows[:14]:
        print(f"   {n[:48]:<48}{x:>8.0f}{y:>9.0f}{(x/y if y else float('inf')):>7.2f}{x-y:>7.0f}")
