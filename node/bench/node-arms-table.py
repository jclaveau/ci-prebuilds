#!/usr/bin/env python3
"""Per-row `X vs Y unit (ratio)` tables for node-perf-kernel arms.

CPU-ms per row: the median over shots of each shot's median, as
assert-perf-gate.py reads it, for every candidate against every reference.

usage: node-arms-table.py <dir> --candidate A [--candidate B]... --reference R [--reference S]...
"""

import argparse
import collections
import glob
import json
import math
import os
import statistics
import sys


def load_cpu_ms(directory):
    arm_rows = collections.defaultdict(lambda: collections.defaultdict(list))
    for path in sorted(glob.glob(os.path.join(directory, "*-node-run*.json"))):
        arm_name = os.path.basename(path).rsplit("-node-run", 1)[0]
        with open(path) as handle:
            document = json.load(handle)
        for row_name, metric in document["metrics"].items():
            arm_rows[arm_name][row_name].append(metric["median_ms"])
    return arm_rows


def cell(value, reference, unit, scale=1.0, digits=1):
    return f"{value / scale:.{digits}f} vs {reference / scale:.{digits}f} {unit} ({value / reference:.3f}x)"


def render_table(title, candidate, references, values_of, unit, scale, digits):
    common_rows = [row_name for row_name in values_of[candidate]
                   if all(row_name in values_of[reference] for reference in references)]
    lines = [f"### {title}", "",
             "| row | " + " | ".join(f"{candidate} vs {reference}" for reference in references) + " |",
             "|---|" + "---:|" * len(references)]
    log_sums = collections.defaultdict(float)
    for row_name in common_rows:
        cells = []
        for reference in references:
            value, reference_value = values_of[candidate][row_name], values_of[reference][row_name]
            cells.append(cell(value, reference_value, unit, scale, digits))
            log_sums[reference] += math.log(value / reference_value)
        lines.append(f"| {row_name} | " + " | ".join(cells) + " |")
    geomeans = [f"**{math.exp(log_sums[reference] / len(common_rows)):.3f}**" for reference in references]
    lines.append("| **geomean** | " + " | ".join(geomeans) + " |")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--candidate", action="append", required=True)
    parser.add_argument("--reference", action="append", required=True)
    args = parser.parse_args()

    arm_rows = load_cpu_ms(args.directory)
    for arm_name in [*args.candidate, *args.reference]:
        if arm_name not in arm_rows:
            raise SystemExit(f"no probe json for arm `{arm_name}` in {args.directory}")
    cpu_medians = {arm_name: {row_name: statistics.median(shots) for row_name, shots in rows.items()}
                   for arm_name, rows in arm_rows.items()}
    shot_counts = {arm_name: min(len(shots) for shots in rows.values()) for arm_name, rows in arm_rows.items()}
    print("shots per arm: " + ", ".join(f"{arm_name} {count}" for arm_name, count in shot_counts.items()) + "\n")

    for candidate in args.candidate:
        print(render_table(f"{candidate}: CPU-ms, median of shot medians", candidate, args.reference,
                           cpu_medians, "ms", 1.0, 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
