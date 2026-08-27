#!/usr/bin/env python3
"""Unit test for the bench's execution index.

The index compares browser speed across scenarios that each ran on their own
hosted runner, so the properties worth pinning are the ones that decide whether
a number is real: enough samples for the median to have converged, and no
kernel in the set that cannot express a difference in the first place.
"""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import exec_index as X  # noqa: E402
from exec_index import exec_cell, exec_index, load_probes, profile  # noqa: E402

failures = 0
checks = 0

METRICS = ["launch", "goto_cold", "layout", "screenshot", "dom_churn", "libm_fmod"]
N = X.MIN_RUNS


def runs(factor, n=None, **overrides):
    """n identical runs whose metrics are `factor` times the 100ms baseline."""
    out = []
    for _ in range(n if n is not None else N):
        metrics = {m: 100.0 * factor for m in METRICS}
        metrics.update(overrides)
        out.append(metrics)
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


base = {("official", "chromium"): runs(1.0)}

# The plain reading.
p = {**base, ("alpine", "chromium"): runs(1.25)}
expect("a 25% slower browser shows +25%", exec_index(p, "alpine", "official")[0], 25.0)
expect_none("the reference row is blank", exec_index(p, "official", "official")[0])

# --- sample count is load-bearing ---
# Subsampling real data put n=3 at sd 6.6% with a worst draw of +40.8% against a
# +15.8% truth, so anything under MIN_RUNS must report nothing rather than a
# number. This is the guard that keeps a fast dispatch from publishing garbage.
thin = {("official", "chromium"): runs(1.0, n=N - 1),
        ("alpine", "chromium"): runs(1.25, n=N - 1)}
expect_none("under MIN_RUNS on both sides", exec_index(thin, "alpine", "official")[0])
half = {("official", "chromium"): runs(1.0),
        ("alpine", "chromium"): runs(1.25, n=N - 1)}
expect_none("under MIN_RUNS on one side", exec_index(half, "alpine", "official")[0])

# --- the median is what cancels the runner lottery ---
# One job landing on a much slower CPU inflates every metric in that sample. The
# median must ignore it; a mean would not.
lottery = {**base, ("alpine", "chromium"): runs(1.25)[:-1] + runs(8.0, n=1)}
expect("an outlier runner is medianed away",
       exec_index(lottery, "alpine", "official")[0], 25.0)

# --- clock-bound kernels cannot discriminate, so they must not dilute ---
# locator_click measured 3333.x ms on BOTH sides, CV 0.0%. Left in, it drags a
# real regression toward parity.
clocked = {
    ("official", "chromium"): runs(1.0, locator_click=3333.0),
    ("alpine", "chromium"): runs(1.5, locator_click=3333.0),
}
expect("a clock-bound kernel does not dilute the index",
       exec_index(clocked, "alpine", "official")[0], 50.0)

# --- parity is a finding, not a reason to drop a metric ---
# screenshot came back ~1.000x for real. It stays, and it correctly pulls a
# mixed picture toward the middle.
mixed = {
    ("official", "chromium"): runs(1.0),
    ("alpine", "chromium"): runs(1.0, screenshot=100.0, launch=400.0),
}
got = exec_index(mixed, "alpine", "official")[0]
checks += 1
if got is None or not (20.0 < got < 30.0):
    print(f"FAIL: a metric at parity still counts — got {got}, wanted 20..30", file=sys.stderr)
    failures += 1

# --- the libc switch ---
libc = {
    ("official", "chromium"): runs(1.0, libm_fmod=170.0),
    ("alpine", "chromium"): runs(1.0, libm_fmod=100.0),
}
X.KEEP_LIBC_METRICS = True
with_libc = exec_index(libc, "alpine", "official")[0]
X.KEEP_LIBC_METRICS = False
without_libc = exec_index(libc, "alpine", "official")[0]
X.KEEP_LIBC_METRICS = True
expect("dropping libm_fmod leaves parity", without_libc, 0.0)
checks += 1
if with_libc is None or with_libc >= -1.0:
    print(f"FAIL: keeping libm_fmod must pull the index below parity — got {with_libc}",
          file=sys.stderr)
    failures += 1

# --- a browser the reference lacks contributes nothing rather than exploding ---
lopsided = {**base, ("alpine", "chromium"): runs(1.5)}
lopsided[("alpine", "webkit")] = runs(99.0)
expect("a browser the reference lacks is skipped",
       exec_index(lopsided, "alpine", "official")[0], 50.0)

expect_none("absent scenario", exec_index(base, "ubuntu", "official")[0])
expect_none("absent reference", exec_index(base, "official", "nosuch")[0])

# --- load_probes / profile ---
with tempfile.TemporaryDirectory() as d:
    for i, launch in enumerate([100.0, 300.0, 200.0]):
        json.dump({"target": "alpine", "browser": "chromium",
                   "metrics": {"launch": {"median_ms": launch}}},
                  open(os.path.join(d, f"{i}.json"), "w"))
    json.dump({"nonsense": True}, open(os.path.join(d, "broken.json"), "w"))
    loaded = load_probes(os.path.join(d, "*.json"))
    checks += 1
    if len(loaded.get(("alpine", "chromium"), [])) != 3:
        print(f"FAIL: load_probes keeps every run — got {loaded}", file=sys.stderr)
        failures += 1
    checks += 1
    if len(loaded) != 1:
        print(f"FAIL: load_probes drops unusable records — got {loaded}", file=sys.stderr)
        failures += 1
    checks += 1
    if profile(loaded[("alpine", "chromium")])["launch"] != 200.0:
        print("FAIL: profile takes the median, not the first or the mean", file=sys.stderr)
        failures += 1

checks += 1
if exec_cell(None, None) != "—" or not exec_cell(-12.0, 3.0).startswith("−12%"):
    print(f"FAIL: exec_cell formatting — {exec_cell(-12.0, 3.0)!r}", file=sys.stderr)
    failures += 1

print(f"exec-index: {checks - failures}/{checks} checks passed")
sys.exit(1 if failures else 0)
