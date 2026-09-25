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

It prints the observed clock TICK per row too, because a CV cannot tell a
precise row from a quantized one -- it reads low either way, and a row whose
every shot repeats the same integer reads lowest of all. That is how libm_fmod
reached the 0.03 `tight` margin its own 1.6%-per-tick clock could never land
on. A margin thinner than two ticks is flagged under the table.

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


RowVerdict = collections.namedtuple(
    "RowVerdict", "row ratio margin cv_candidate cv_reference tick_fraction breach"
)

# runtime-probe.cjs writes median_ms with toFixed(3), so no row can reveal a
# clock finer than this however stable it reads.
WRITE_GRID_MS = 0.001

# A ceiling is landable only if the margin spans at least this many ticks:
# below it the reachable ratios straddle the ceiling and the row reads clean or
# overshoots, never near.
TICKS_PER_MARGIN_FLOOR = 2


def greatest_common_step(left, right):
    """Euclid on reals, stopped at the grid the probe writes on."""
    while right > WRITE_GRID_MS:
        left, right = right, math.fmod(left, right)
    return left


def observed_tick(*shot_lists):
    """The coarsest step every shot is a multiple of: the clock's resolution as
    these shots reveal it.

    WebKit clamps performance.now() to 1 ms, so its in-page rows come back as
    whole integers and this reads 1.0; a row timed from node reads the 0.001
    floor. Drift in the float arithmetic can only shrink the result, which
    floors to the grid -- the detector under-claims, never over-claims.
    """
    step = 0.0
    for shots in shot_lists:
        for value in shots:
            step = greatest_common_step(step, value)
    # Snap to the grid: Euclid leaves the last remainder just off it, so a
    # decimal row would otherwise report 0.001000000256 and read as a clock
    # nobody has.
    return max(round(step / WRITE_GRID_MS) * WRITE_GRID_MS, WRITE_GRID_MS)


def compare(arms, candidate, reference, browser, margins):
    """[RowVerdict], geomean, geo_breach."""
    rows = sorted(set(arms[candidate]) & set(arms[reference]))
    table, logs = [], []
    for row in rows:
        c_shots, r_shots = arms[candidate][row], arms[reference][row]
        c, r = statistics.median(c_shots), statistics.median(r_shots)
        ratio = c / r
        margin = margin_for(margins, browser, row)
        cv = lambda shots: statistics.pstdev(shots) / statistics.mean(shots)
        # Against the REFERENCE: adjacent reachable ratios are one tick of the
        # denominator apart, so that is the resolution of this row's verdict.
        table.append(RowVerdict(row, ratio, margin, cv(c_shots), cv(r_shots),
                                observed_tick(c_shots, r_shots) / r,
                                ratio > 1 + margin))
        logs.append(math.log(ratio))
    geomean = math.exp(sum(logs) / len(logs)) if logs else float("nan")
    return table, geomean, geomean > 1 + margins["geomean"]


def unresolvable(table):
    """Rows whose ceiling falls between two reachable ratios.

    A quantized row hides as a PRECISE one: libm_fmod read cv 0.008 while every
    shot repeated the same integer, and that low cv is what argued it onto the
    `tight` margin the row could never land on (run 35848464161 passed at 1.022
    and 35972784207 breached at 1.044, with nothing reachable in between).
    """
    return [item for item in table
            if item.margin < TICKS_PER_MARGIN_FLOOR * item.tick_fraction]


def render(title, table, geomean, geo_breach, geo_margin):
    out = [f"### {title}", "",
           "| row | ratio | ceiling | cv cand | cv ref | tick | |",
           "|---|---:|---:|---:|---:|---:|---|"]
    coarse_rows = {item.row for item in unresolvable(table)}
    for item in table:
        flag = "❌" if item.breach else ("≈" if item.ratio > 1 else "✅")
        coarse = " ⚠" if item.row in coarse_rows else ""
        out.append(f"| {item.row} | {item.ratio:.3f} | {1 + item.margin:.2f} "
                   f"| {item.cv_candidate:.3f} | {item.cv_reference:.3f} "
                   f"| {item.tick_fraction:.1%}{coarse} | {flag} |")
    out.append(f"| **geomean** | **{geomean:.3f}** | {1 + geo_margin:.2f} | | | | {'❌' if geo_breach else '✅'} |")
    out.append("")
    return "\n".join(out)


def render_unresolvable(table):
    """Named under the table, because a quantized row's verdict is not evidence
    either way -- neither its red nor its green."""
    coarse_rows = unresolvable(table)
    if not coarse_rows:
        return ""
    out = ["### ⚠ Rows the clock cannot resolve", "",
           "One tick of the page clock is a larger share of these rows than half",
           "their margin, so the reachable ratios straddle the ceiling: the row",
           "reads clean or overshoots, never near. Read neither verdict as a",
           "measurement. Fix by sizing the kernel so one tick is under ~0.5% of",
           "it (runtime-probe.cjs, SIZING RULE), not by widening the margin.", ""]
    for item in coarse_rows:
        ticks = item.margin / item.tick_fraction
        out.append(f"- `{item.row}` — tick {item.tick_fraction:.2%} of the reference, "
                   f"margin {item.margin:.2f} spans {ticks:.1f} ticks")
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
    failed |= geo_breach or any(item.breach for item in table)
    print(render(f"parity — {args.candidate} / {args.control}", table, geomean, geo_breach, margins["geomean"]))
    parity_table = table

    if has_promoted:
        table, geomean, geo_breach = compare(arms, args.candidate, args.promoted, args.browser, margins)
        failed |= geo_breach or any(item.breach for item in table)
        print(render(f"ratchet — {args.candidate} / {args.promoted}", table, geomean, geo_breach, margins["geomean"]))
    else:
        print(f"### ratchet — skipped: no `{args.promoted}` arm (first promotion of this channel)\n")

    # Parity's alone: both comparisons share the candidate's clock, so a row
    # coarse against official is coarse against promoted, and saying it twice
    # reads as two findings.
    coarse_note = render_unresolvable(parity_table)
    if coarse_note:
        print(coarse_note)

    print("≈ = over 1.00 but inside the row's noise margin: a tie, not a win.")
    print("tick = one step of the clock that timed the row, as a share of the")
    print("reference; ⚠ marks a margin thinner than two of them.\n")
    print("**BREACH — not promoting.**" if failed else "**PASS — faster than official, no slower than promoted.**")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
