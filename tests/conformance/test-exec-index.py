#!/usr/bin/env python3
"""Unit test for the bench's CPU-normalized execution index.

The whole point of the index is that it survives the runner lottery: the bench
gives every scenario its own machine, and hosted CPU models differ by 20-30%. A
version of this that reported machine speed as browser speed would look
perfectly reasonable in the table, so the machine-cancels property is asserted
first and directly.
"""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
from exec_index import exec_cell, exec_index, load_probes  # noqa: E402

failures = 0
checks = 0

METRICS = ["launch", "goto_cold", "layout", "screenshot", "dom_churn", "libm_fmod"]


def probes(**scenarios):
    """{scenario: (cpu_factor, browser_factor)} -> a probe dict.

    cpu_factor scales EVERY metric including the normalizer, so it stands for a
    slower runner. browser_factor scales only the measured metrics, so it stands
    for a slower browser. The index must see the second and not the first.
    """
    out = {}
    for name, (cpu, browser) in scenarios.items():
        metrics = {"int_math": 40.0 * cpu}
        for i, metric in enumerate(METRICS):
            metrics[metric] = (100.0 + i) * cpu * browser
        out[(name, "chromium")] = metrics
    return out


def expect(label, got, want, tolerance=0.5):
    global failures, checks
    checks += 1
    if got is None or abs(got - want) > tolerance:
        print(f"FAIL: {label} — got {got}, wanted {want}", file=sys.stderr)
        failures += 1


def expect_none(label, got):
    global failures, checks
    checks += 1
    if got is not None:
        print(f"FAIL: {label} — got {got}, wanted None", file=sys.stderr)
        failures += 1


# The load-bearing one: same browser, a runner 2x slower. Every raw ms doubles,
# and the index must still read parity.
p = probes(official=(1.0, 1.0), alpine=(2.0, 1.0))
expect("a 2x slower runner cancels", exec_index(p, "alpine", "official")[0], 0.0)

# Same runner, a browser 25% slower.
p = probes(official=(1.0, 1.0), alpine=(1.0, 1.25))
expect("a 25% slower browser shows +25%", exec_index(p, "alpine", "official")[0], 25.0)

# Both at once — the browser delta must survive the machine delta untouched.
p = probes(official=(1.0, 1.0), alpine=(3.0, 0.80))
expect("browser gain survives a 3x slower runner",
       exec_index(p, "alpine", "official")[0], -20.0)

# The reference compares to nothing.
expect_none("reference row is blank", exec_index(p, "official", "official")[0])

# A scenario with no probe at all, and a reference with none.
expect_none("absent scenario", exec_index(p, "ubuntu", "official")[0])
expect_none("absent reference", exec_index(p, "alpine", "nosuch")[0])

# Too few usable metrics is not a geometric mean.
thin = {("official", "chromium"): {"int_math": 40.0, "launch": 100.0},
        ("alpine", "chromium"): {"int_math": 40.0, "launch": 150.0}}
expect_none("one metric is not a geomean", exec_index(thin, "alpine", "official")[0])

# int_math must not be counted as one of the metrics: with it excluded these two
# scenarios differ on every remaining metric by exactly 50%.
half = {("official", "chromium"): {"int_math": 40.0, **{m: 100.0 for m in METRICS}},
        ("alpine", "chromium"): {"int_math": 40.0, **{m: 150.0 for m in METRICS}}}
expect("normalizer excluded from the index",
       exec_index(half, "alpine", "official")[0], 50.0)

# A browser present on one side only contributes nothing rather than exploding.
mixed = dict(probes(official=(1.0, 1.0), alpine=(1.0, 1.5)))
mixed[("alpine", "webkit")] = {"int_math": 40.0, **{m: 999.0 for m in METRICS}}
expect("a browser the reference lacks is skipped",
       exec_index(mixed, "alpine", "official")[0], 50.0)

# load_probes: newest-wins is wrong, least-contended-wins is the rule.
with tempfile.TemporaryDirectory() as d:
    for i, norm in enumerate([40.0, 80.0]):
        json.dump({"target": "alpine", "browser": "chromium",
                   "metrics": {"int_math": {"median_ms": norm},
                               "launch": {"median_ms": 100.0}}},
                  open(os.path.join(d, f"{i}.json"), "w"))
    json.dump({"nonsense": True}, open(os.path.join(d, "broken.json"), "w"))
    loaded = load_probes(os.path.join(d, "*.json"))
    checks += 1
    if loaded.get(("alpine", "chromium"), {}).get("int_math") != 40.0:
        print(f"FAIL: load_probes keeps the fastest normalizer — got {loaded}", file=sys.stderr)
        failures += 1
    checks += 1
    if len(loaded) != 1:
        print(f"FAIL: load_probes drops unusable records — got {loaded}", file=sys.stderr)
        failures += 1

checks += 1
if exec_cell(None, None) != "—" or not exec_cell(-12.0, 3.0).startswith("−12%"):
    print(f"FAIL: exec_cell formatting — {exec_cell(-12.0, 3.0)!r}", file=sys.stderr)
    failures += 1

print(f"exec-index: {checks - failures}/{checks} checks passed")
sys.exit(1 if failures else 0)
