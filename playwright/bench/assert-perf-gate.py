#!/usr/bin/env python3
"""The promote gate: a build ships only if it is faster than official Playwright
AND no slower than the build it replaces.

Three arms, probed in one job on one runner so their numbers divide cleanly:

  candidate   the artifact this run built, staged through the consumer image
  promoted    what <browser>-latest points at today, staged the same way
  official    mcr.microsoft.com/playwright, the parity reference

Per row, over `runs` shots each, the median of the shots' medians. Two ratios
must both sit at or under 1.00 plus the row's noise margin
(perf-gate-margins.json), and the geomean over rows at or under 1.00 plus the
geomean margin:

  parity   candidate / official   <= 1 + margin     (all three browsers)
  ratchet  candidate / promoted   <= 1 + margin     (skipped, and said so, when
                                                     no promoted arm exists)

The margins are noise, not allowance: a candidate that reads 1.02 on a 0.03
row is a tie, not a win. The summary prints the observed shot-to-shot CV per
row beside the margin so an over- or under-sized margin is visible from a
passing run.

Structural checks first, as in assert-perf-budgets.py: every arm that ran must
have every row, with `runs` shots, and no median may be zero or NaN. A gate
that can go green on an empty directory measures nothing.

usage: assert-perf-gate.py <dir-of-probe-json> --browser B
           [--candidate candidate] [--promoted promoted] [--control official]
           [--runs 5] [--margins perf-gate-margins.json]
Prints a markdown summary on stdout, exits 1 on any breach.
"""

import argparse
import collections
import glob
import json
import math
import os
import statistics
import sys


def load(directory, browser):
    """{arm: {row: [median_ms per shot]}} from <arm>-<browser>-runN.json."""
    arms = collections.defaultdict(lambda: collections.defaultdict(list))
    for path in sorted(glob.glob(os.path.join(directory, f"*-{browser}-run*.json"))):
        stem = os.path.basename(path)[: -len(".json")]
        arm = stem.rsplit(f"-{browser}-run", 1)[0]
        with open(path) as fh:
            doc = json.load(fh)
        for row, metric in doc.get("metrics", {}).items():
            arms[arm][row].append(metric.get("median_ms"))
    return arms


def margin_for(margins, browser, row):
    if row in margins["tight"]["rows"]:
        return margins["tight"]["margin"]
    if row in margins["loose"].get(browser, []):
        return margins["loose"]["margin"]
    return margins["default"]


def check_structure(arms, expected_arms, runs):
    problems = []
    for arm in expected_arms:
        if arm not in arms:
            problems.append(f"arm `{arm}` produced no probe json")
    rows = set()
    for arm in arms.values():
        rows |= set(arm)
    for arm_name, arm in arms.items():
        for row in sorted(rows):
            shots = arm.get(row, [])
            if len(shots) != runs:
                problems.append(f"`{arm_name}` / `{row}`: {len(shots)} shots, expected {runs}")
            for value in shots:
                if value is None or not math.isfinite(value) or value <= 0:
                    problems.append(f"`{arm_name}` / `{row}`: median {value!r}")
    return problems


def compare(arms, candidate, reference, browser, margins):
    """[(row, ratio, margin, cv_candidate, cv_reference, breach)], geomean, geo_breach."""
    rows = sorted(set(arms[candidate]) & set(arms[reference]))
    table, logs = [], []
    for row in rows:
        c_shots, r_shots = arms[candidate][row], arms[reference][row]
        c, r = statistics.median(c_shots), statistics.median(r_shots)
        ratio = c / r
        margin = margin_for(margins, browser, row)
        cv = lambda shots: statistics.pstdev(shots) / statistics.mean(shots)
        table.append((row, ratio, margin, cv(c_shots), cv(r_shots), ratio > 1 + margin))
        logs.append(math.log(ratio))
    geomean = math.exp(sum(logs) / len(logs)) if logs else float("nan")
    return table, geomean, geomean > 1 + margins["geomean"]


def render(title, table, geomean, geo_breach, geo_margin):
    out = [f"### {title}", "", "| row | ratio | ceiling | cv cand | cv ref | |", "|---|---:|---:|---:|---:|---|"]
    for row, ratio, margin, cv_c, cv_r, breach in table:
        flag = "❌" if breach else ("≈" if ratio > 1 else "✅")
        out.append(f"| {row} | {ratio:.3f} | {1 + margin:.2f} | {cv_c:.3f} | {cv_r:.3f} | {flag} |")
    out.append(f"| **geomean** | **{geomean:.3f}** | {1 + geo_margin:.2f} | | | {'❌' if geo_breach else '✅'} |")
    out.append("")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--browser", required=True)
    parser.add_argument("--candidate", default="candidate")
    parser.add_argument("--promoted", default="promoted")
    parser.add_argument("--control", default="official")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument(
        "--margins",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf-gate-margins.json"),
    )
    args = parser.parse_args()

    with open(args.margins) as fh:
        margins = json.load(fh)
    arms = load(args.directory, args.browser)

    has_promoted = args.promoted in arms
    expected = [args.candidate, args.control] + ([args.promoted] if has_promoted else [])
    problems = check_structure(arms, expected, args.runs)
    if problems:
        print(f"## {args.browser} promote gate — INVALID\n")
        for problem in problems:
            print(f"- {problem}")
        return 1

    print(f"## {args.browser} promote gate — {args.runs} shots per arm, one runner\n")
    failed = False

    table, geomean, geo_breach = compare(arms, args.candidate, args.control, args.browser, margins)
    failed |= geo_breach or any(item[-1] for item in table)
    print(render(f"parity — {args.candidate} / {args.control}", table, geomean, geo_breach, margins["geomean"]))

    if has_promoted:
        table, geomean, geo_breach = compare(arms, args.candidate, args.promoted, args.browser, margins)
        failed |= geo_breach or any(item[-1] for item in table)
        print(render(f"ratchet — {args.candidate} / {args.promoted}", table, geomean, geo_breach, margins["geomean"]))
    else:
        print(f"### ratchet — skipped: no `{args.promoted}` arm (first promotion of this channel)\n")

    print("≈ = over 1.00 but inside the row's noise margin: a tie, not a win.\n")
    print("**BREACH — not promoting.**" if failed else "**PASS — faster than official, no slower than promoted.**")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
