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

Invalid cells: the arms of one draw run sequentially inside a single job, so a
machine that slows down partway through leaves our arm measured against a
control taken while it was still fast. Two rows exist that no build change moves
together — `int_math` and `libm_fmod` — and when BOTH move by the same amount
the cell is drifted rather than regressed. A breach is then excused only if
dividing that drift out brings the row inside its budget. See the
`_invalid_cell` block in perf-budgets.json for the sizing and the worked example.

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


def cell_drift(ratios, config):
    """The factor by which this arm's whole measurement ran slow, or None.

    None means the cell is trustworthy: either a control is missing, or they
    disagree, or one of them is far enough out that it is a finding rather than
    drift.
    """
    controls = config.get("controls") or []
    values = [ratios[row] for row in controls if ratios.get(row)]
    if len(values) != len(controls) or not values:
        return None
    if max(values) >= config.get("hard_ceiling", 1.5):
        return None
    if min(values) < config.get("min_shift", 1.05):
        return None
    if max(values) / min(values) > config.get("spread", 1.05):
        return None
    product = 1.0
    for value in values:
        product *= value
    return product ** (1.0 / len(values))


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
        doc = json.load(fh)
    drift_config = doc.get("_invalid_cell") or {}
    budgets = {k: v for k, v in doc.items() if not k.startswith("_")}

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
            cell = f"{browser}/{target}"
            ratios = {}
            for row in sorted(rows):
                a, o = targets[target].get(row), control.get(row)
                for label, value in (("ours", a), (CONTROL, o)):
                    if value is None:
                        errors.append(f"{cell}: row `{row}` missing from {label}")
                    elif not math.isfinite(value) or value <= 0:
                        errors.append(f"{cell}: row `{row}` is {value} in {label}")
                if a is not None and o is not None and a > 0 and o > 0:
                    ratios[row] = a / o

            # Computed before any row is judged, because it decides how every
            # one of them is judged.
            drift = cell_drift(ratios, drift_config)
            if drift:
                print(
                    f"::warning::{cell}: every control row moved together "
                    f"({', '.join(f'{r} {ratios[r]:.2f}x' for r in drift_config['controls'])})"
                    f" — the arm ran {drift:.2f}x slow against its own control, so this"
                    " cell is drifted, not regressed. Re-measure before reading it."
                )

            for row, ceiling in sorted(rows.items()):
                ratio = ratios.get(row)
                if ratio is None:
                    continue
                adjusted = ratio / drift if drift else ratio
                if ratio <= ceiling:
                    mark = "ok"
                elif adjusted <= ceiling:
                    mark = f"DRIFT ({adjusted:.2f}x adjusted)"
                else:
                    mark = "FAIL"
                print(f"  {cell:<24} {row:<15} {ratio:5.2f}x  budget {ceiling:.2f}  {mark}")
                if ratio > ceiling and adjusted > ceiling:
                    # Reported at the adjusted ratio on a drifted cell: the raw
                    # number is the one the drift already explains part of, and
                    # quoting it would send someone hunting for the wrong size
                    # of regression.
                    errors.append(
                        f"{cell}: `{row}` {adjusted:.2f}x exceeds its {ceiling:.2f}x budget"
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
