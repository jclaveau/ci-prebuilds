#!/usr/bin/env python3
"""Render jsc-kernels.cjs output as one table per JIT arm.

The reading it is built for: compare `official/ftl-off` against
`alpine/default`. If forcing official down a tier lands it on our default
number, our build is not reaching that tier; if official stays fast with FTL
off, the tiers agree and the gap is in the compiled C++ of the tier itself.
"""
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "jsc-out")
runs = {}
for path in sorted(src.glob("*.json")):
    data = json.loads(path.read_text())
    runs[(data["target"], data["arm"])] = data

if not runs:
    print("_no jsc-kernels output_")
    sys.exit(0)

arms = sorted({arm for _, arm in runs})
kernels = sorted({k for run in runs.values() for k in run["metrics"]})

print("| kernel | " + " | ".join(
    f"official {a} | alpine {a} | ×off" for a in arms) + " |")
print("|---" * (1 + 3 * len(arms)) + "|")
for kernel in kernels:
    cells = []
    for arm in arms:
        off = runs.get(("official", arm), {}).get("metrics", {}).get(kernel)
        ours = runs.get(("alpine", arm), {}).get("metrics", {}).get(kernel)
        ratio = f"{ours / off:.2f}x" if off and ours else "—"
        cells += [f"{off:,.1f}" if off else "—",
                  f"{ours:,.1f}" if ours else "—", ratio]
    print(f"| `{kernel}` | " + " | ".join(cells) + " |")

print()
for (target, arm), data in sorted(runs.items()):
    # An arm whose JSC_* env never reached the WebProcess would otherwise be
    # indistinguishable from an arm where the option changed nothing.
    print(f"- `{target}/{arm}`: JSC env {data['jscEnv'] or '{}'}, "
          f"cpu `{data['cpu']}`")
