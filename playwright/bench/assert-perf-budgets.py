#!/usr/bin/env python3
"""Fail when the runtime probe produced nothing, or when a row blew its budget.

Two checks, and the FIRST one is the one that earns its keep.

Structural: until this existed, `perf-report.py` returned quietly on an empty
directory and the job was marked continue-on-error, so every cell could fail to
launch and the run still went green. A probe that cannot go red measures
nothing. So: the `official` control must be present for every browser that
reported, each browser needs at least one of our images beside it, every
budgeted row must be there, and no median may be zero, negative or NaN.

Budgets: per (browser, row) ceilings on the alpine/official ratio, from
perf-budgets.json. Deliberately not the <= 1.00 parity goal — ten of thirteen
firefox rows are statistical ties at n=10, so gating on parity would paint main
red by coin flip. These catch the class of regression that motivated the probe:
chromium shipped with DCHECKs compiled in for months and `int_math` read 5-9x
while every test stayed green.

The ratio is only meaningful within one run, since each run divides out its own
runner, so nothing here compares against a previous run.

usage: assert-perf-budgets.py <dir-of-probe-json> [budgets.json]
"""

import collections
import glob
import json
import math
import os
import sys

CONTROL = "official"


def load(directory):
    """{browser: {target: {metric: median_ms}}} from <target>-<browser>*.json."""
    out = collections.defaultdict(dict)
    for path in sorted(glob.glob(os.path.join(directory, "*.json"))):
        stem = os.path.basename(path)[: -len(".json")]
        # <target>-<browser>[-runN]; browser is the last non-run segment.
        parts = stem.split("-")
        if parts[-1].startswith("run"):
            parts = parts[:-1]
        if len(parts) < 2:
            continue
        target, browser = "-".join(parts[:-1]), parts[-1]
        with open(path) as fh:
            doc = json.load(fh)
        metrics = {k: v.get("median_ms") for k, v in (doc.get("metrics") or {}).items()}
        # perf-probe writes one file per repetition; keep the first, the report
        # is what medians across them. A budget breach shows in any of them.
        out[browser].setdefault(target, metrics)
    return out


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else "perf-current"
    budget_path = (
        sys.argv[2]
        if len(sys.argv) > 2
        else os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-budgets.json")
    )
    with open(budget_path) as fh:
        budgets = {k: v for k, v in json.load(fh).items() if not k.startswith("_")}

    data = load(root)
    errors = []

    if not data:
        print(f"::error::no probe JSON under {root} — the probe produced nothing")
        return 1

    for browser in sorted(data):
        targets = data[browser]
        if CONTROL not in targets:
            errors.append(f"{browser}: no `{CONTROL}` control — nothing to divide by")
            continue
        ours = [t for t in targets if t != CONTROL]
        if not ours:
            errors.append(f"{browser}: control present but none of our images reported")
            continue

        rows = budgets.get(browser)
        if rows is None:
            print(f"::warning::{browser} has no budgets entry — add one to perf-budgets.json")
            continue

        control = targets[CONTROL]
        for target in sorted(ours):
            for row, ceiling in sorted(rows.items()):
                a, o = targets[target].get(row), control.get(row)
                for label, value in (("ours", a), (CONTROL, o)):
                    if value is None:
                        errors.append(f"{browser}/{target}: row `{row}` missing from {label}")
                    elif not math.isfinite(value) or value <= 0:
                        errors.append(f"{browser}/{target}: row `{row}` is {value} in {label}")
                if a is None or o is None or not (a > 0 and o > 0):
                    continue
                ratio = a / o
                mark = "FAIL" if ratio > ceiling else "ok"
                cell = f"{browser}/{target}"
                print(f"  {cell:<24} {row:<15} {ratio:5.2f}x  budget {ceiling:.2f}  {mark}")
                if ratio > ceiling:
                    errors.append(
                        f"{browser}/{target}: `{row}` {ratio:.2f}x exceeds its {ceiling:.2f}x budget"
                    )

        for row in sorted(set(control) - set(rows)):
            print(f"::warning::{browser}: row `{row}` has no budget — add one to perf-budgets.json")

    if errors:
        for err in errors:
            print(f"::error::{err}")
        print(f"\nFAIL: {len(errors)} perf assertion(s) failed")
        return 1
    print("\nPASS: every browser reported against its control and every row is within budget")
    return 0


if __name__ == "__main__":
    sys.exit(main())
