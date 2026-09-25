#!/usr/bin/env python3
"""Unit test for the promote gate.

The gate reds and greens every browser build, and until 2026-09-25 it had no
test at all. What it got wrong for three runs is the subject of half the cases
below: it reported a CV per row as the evidence for sizing a margin, and a CV
cannot tell a precise row from a quantized one. WebKit clamps
performance.now() to 1 ms, so `libm_fmod` came back as the same integer on
every shot -- CV 0.008, the lowest on the board -- and that argued it onto the
0.03 `tight` margin, which sits between the only two ratios a 62 ms row on a
1 ms clock can produce (1.000 and 1.044).

Runs against no network and no browser: every case hands `compare` literal
shot lists, and the end-to-end case writes the probe json the gate reads.
"""
import json
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "playwright" / "bench"))
import importlib.util  # noqa: E402

# No .pyc for the module under test: a mutation run rewrites the gate many
# times a second, and CPython accepts a cached .pyc whose recorded mtime and
# size still match -- so an edited gate silently ran the previous version's
# bytecode and reported its mutants killed.
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location(
    "assert_perf_gate",
    pathlib.Path(__file__).resolve().parents[2] / "playwright" / "bench" / "assert-perf-gate.py",
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

GATE_PATH = pathlib.Path(__file__).resolve().parents[2] / "playwright" / "bench" / "assert-perf-gate.py"

MARGINS = {
    "geomean": 0.02,
    "default": 0.06,
    "tight": {"rows": ["int_math", "libm_fmod"], "margin": 0.03},
    "loose": {"webkit": ["eval_rtt"], "margin": 0.10},
}

failures = 0
checks = 0


def check(label, got, want):
    global failures, checks
    checks += 1
    if got != want:
        print(f"FAIL: {label} — got {got!r}, wanted {want!r}", file=sys.stderr)
        failures += 1


def near(label, got, want, tol):
    global failures, checks
    checks += 1
    if got is None or abs(got - want) > tol:
        print(f"FAIL: {label} — {got!r} is more than {tol} from {want!r}", file=sys.stderr)
        failures += 1


def arms_from(rows):
    """{arm: {row: shots}} — `rows` is {row: {arm: shots}}, the way a case reads."""
    arms = {}
    for row, per_arm in rows.items():
        for arm, shots in per_arm.items():
            arms.setdefault(arm, {})[row] = shots
    return arms


# --------------------------------------------------------------- observed_tick

# WebKit's in-page rows, run 36048405627: every shot the same whole millisecond.
check("whole-ms shots reveal a 1 ms clock",
      gate.observed_tick([61.0, 61.0, 61.0, 62.0, 61.0]), 1.0)

# A row timed from node (process.hrtime.bigint) instead of the page.
check("decimal shots floor at the write grid",
      gate.observed_tick([69.313, 70.1, 69.42, 71.008, 69.3]), 0.001)

# int_math, run 36126861080: all ten shots of both arms read 188.0. Their
# greatest common step is 188, and reading the tick that way claimed a 188 ms
# clock and flagged the steadiest row on the board. The decimal grid cannot.
check("identical shots claim one tick, not their own value",
      gate.observed_tick([62.0, 62.0, 62.0, 62.0, 62.0]), 1.0)
check("a steady decimal row reads its own grid, not its own value",
      gate.observed_tick([69.5, 69.5, 69.5]), 0.1)

# 48 = 32 x 1.5 and 46.5 = 31 x 1.5, so the common step is 1.5 -- but nothing
# ticks every 1.5 ms, and 46.5 is written on the 0.1 grid. The first arm read
# alone sits on 1.0, so the two arms genuinely disagree.
check("both arms are read together",
      gate.observed_tick([48.0, 48.0], [46.5, 46.5]), 0.1)
check("one arm alone reads a different grid",
      gate.observed_tick([48.0, 48.0]), 1.0)

check("a whole-ms arm beside a decimal arm floors to the finer grid",
      gate.observed_tick([61.0, 61.0], [58.25, 58.5]), 0.01)

check("one tenth anywhere pulls the whole row down a decade",
      gate.observed_tick([188.0, 187.5]), 0.1)
check("no shot list claims a clock coarser than one tick",
      gate.observed_tick([2000.0, 4000.0]), 1.0)

# ------------------------------------------------------------------- compare

# The gate reduces with the MEDIAN of the shots' medians, never the mean: the
# mean of these five is 50.0 and the median is 47.0, and only 47/46 = 1.022 is
# the ratio run 35848464161 reported.
table, geomean, geo_breach = gate.compare(
    arms_from({"libm_fmod": {"candidate": [47.0, 47.0, 47.0, 47.0, 62.0],
                             "official": [46.0, 46.0, 46.0, 46.0, 46.0]}}),
    "candidate", "official", "webkit", MARGINS)
near("ratio is median over median, not mean over mean", table[0].ratio, 47.0 / 46.0, 0.0005)
check("row name", table[0].row, "libm_fmod")
check("tight margin applies", table[0].margin, 0.03)
near("tick is one clock step over the reference", table[0].tick_fraction, 1.0 / 46.0, 0.0001)
check("1.022 is under the 1.03 ceiling", table[0].breach, False)

check("loose margin applies per browser",
      gate.margin_for(MARGINS, "webkit", "eval_rtt"), 0.10)
check("loose does not cross browsers",
      gate.margin_for(MARGINS, "firefox", "eval_rtt"), 0.06)

# The shipped file, not the fixture above: `loose` was retired browser by
# browser (firefox 2026-09-16, webkit 2026-09-25) once gate runs priced the
# rows, and nothing may quietly take it back. eval_rtt is the node<->CDP round
# trip, identical on all three arms -- a control that may swing 10% is not a
# control -- and click_force reads 1.023-1.043 against official in every draw,
# a standing gap 1.10 was calling green.
SHIPPED = json.loads((pathlib.Path(__file__).resolve().parents[2]
                      / "playwright" / "bench" / "perf-gate-margins.json").read_text())
check("no browser holds a loose margin",
      [key for key in SHIPPED["loose"] if not key.startswith("_") and key != "margin"], [])
check("webkit eval_rtt takes the default", gate.margin_for(SHIPPED, "webkit", "eval_rtt"), 0.06)
check("webkit click_force takes the default",
      gate.margin_for(SHIPPED, "webkit", "click_force"), 0.06)
check("the rows that price a build stay tight",
      gate.margin_for(SHIPPED, "webkit", "libm_fmod"), 0.03)
check("default margin otherwise",
      gate.margin_for(MARGINS, "webkit", "goto_cold"), 0.06)

# ------------------------------------------------------------- unresolvable

# Run 36048405627 as it actually read: candidate 61, official 58, tight 0.03.
# One tick is 1.7% of 58, so the reachable ratios step 1.000, 1.017, 1.034 --
# the 1.03 ceiling lands between two of them and the row can never read near it.
breached_table, _, _ = gate.compare(
    arms_from({"libm_fmod": {"candidate": [61.0] * 5, "official": [58.0] * 5}}),
    "candidate", "official", "webkit", MARGINS)
check("a 62 ms row on a 1 ms clock breaches 1.03", breached_table[0].breach, True)
check("and is named unresolvable",
      [item.row for item in gate.unresolvable(breached_table)], ["libm_fmod"])

# The same row after runtime-probe.cjs went 9M -> 36M iterations: one tick is
# 0.4% of 236 ms, the 0.03 margin spans 7 ticks, and the verdict means something.
resized_table, _, _ = gate.compare(
    arms_from({"libm_fmod": {"candidate": [248.0, 247.0, 248.0, 249.0, 248.0],
                             "official": [236.0, 236.0, 237.0, 236.0, 235.0]}}),
    "candidate", "official", "webkit", MARGINS)
check("a 248 ms row on the same clock resolves", gate.unresolvable(resized_table), [])
check("and still breaches on its own merits", resized_table[0].breach, True)

# The flag is about the INSTRUMENT, so a row that passes is flagged too — run
# 35848464161 read 1.022 and green on a clock just as coarse.
passing_table, _, _ = gate.compare(
    arms_from({"libm_fmod": {"candidate": [47.0] * 5, "official": [46.0] * 5}}),
    "candidate", "official", "webkit", MARGINS)
check("a PASSING quantized row is flagged too", passing_table[0].breach, False)
check("because the flag reads the clock, not the verdict",
      [item.row for item in gate.unresolvable(passing_table)], ["libm_fmod"])

# A decimal row must never trip it, whatever its margin.
decimal_table, _, _ = gate.compare(
    arms_from({"launch": {"candidate": [69.313, 70.1, 69.42, 71.008, 69.3],
                          "official": [68.2, 68.91, 69.004, 68.5, 68.77]}}),
    "candidate", "official", "webkit", MARGINS)
check("a node-timed row is never unresolvable", gate.unresolvable(decimal_table), [])

# A wide margin absorbs a coarse clock: eval_rtt is whole-ms too, but `loose`
# 0.10 against a 232 ms row spans 23 ticks.
loose_table, _, _ = gate.compare(
    arms_from({"eval_rtt": {"candidate": [232.0] * 5, "official": [230.0] * 5}}),
    "candidate", "official", "webkit", MARGINS)
check("a margin wider than two ticks is not flagged", gate.unresolvable(loose_table), [])

# int_math as run 36126861080 really measured it: a stable 188 ms row where
# every shot of both arms agreed. The first tick column called that a 188 ms
# clock -- 100% of the reference -- and flagged the steadiest row on the board.
steady_table, _, _ = gate.compare(
    arms_from({"int_math": {"candidate": [188.0] * 5, "official": [188.0] * 5}}),
    "candidate", "official", "webkit", MARGINS)
near("a row every shot agrees on still reads one tick",
     steady_table[0].tick_fraction, 1.0 / 188.0, 0.0001)
check("and resolves, because 0.03 spans 5 ticks of it", gate.unresolvable(steady_table), [])

# ---------------------------------------------------------------- structure

check("a missing arm is a structural problem",
      gate.check_structure({"candidate": {"launch": [1.0]}}, ["candidate", "official"], 1),
      ["arm `official` produced no probe json"])

check("a short shot count is a structural problem",
      gate.check_structure({"candidate": {"launch": [1.0, 2.0]}}, ["candidate"], 5),
      ["`candidate` / `launch`: 2 shots, expected 5"])

check("a zero median is a structural problem",
      gate.check_structure({"candidate": {"launch": [0.0]}}, ["candidate"], 1),
      ["`candidate` / `launch`: median 0.0"])

# ------------------------------------------------------------------- render

rendered = gate.render("parity", breached_table, 1.052, False, 0.02)
check("the table carries a tick column", "| tick |" in rendered, True)
check("a coarse row is marked in its row", "1.7% ⚠" in rendered, True)
check("a breached row keeps its ❌", "| ❌ |" in rendered, True)

named = gate.render_unresolvable(breached_table)
check("the coarse row is named under the table", "`libm_fmod`" in named, True)
check("with how many ticks its margin spans", "spans 1.7 ticks" in named, True)
check("a resolvable table prints no section", gate.render_unresolvable(resized_table), "")

# --------------------------------------------------------------- end to end

def run_gate(rows, runs):
    """Write the probe json the gate globs for, run it, return (rc, stdout)."""
    with tempfile.TemporaryDirectory() as directory:
        for arm in ("candidate", "promoted", "official"):
            for shot in range(1, runs + 1):
                metrics = {row: {"median_ms": per_arm[arm][shot - 1]}
                           for row, per_arm in rows.items()}
                path = pathlib.Path(directory) / f"{arm}-webkit-run{shot}.json"
                path.write_text(json.dumps({"metrics": metrics}))
        margins_path = pathlib.Path(directory) / "margins.json"
        margins_path.write_text(json.dumps(MARGINS))
        done = subprocess.run(
            [sys.executable, str(GATE_PATH), directory, "--browser", "webkit",
             "--runs", str(runs), "--margins", str(margins_path)],
            capture_output=True, text=True)
        return done.returncode, done.stdout


# Coarse AND passing: the flag must not turn a green run red.
rc, out = run_gate({"libm_fmod": {"candidate": [47.0] * 5,
                                  "promoted": [47.0] * 5,
                                  "official": [46.0] * 5},
                    "launch": {"candidate": [69.3] * 5,
                               "promoted": [69.4] * 5,
                               "official": [70.0] * 5}}, 5)
check("a coarse row does not fail the gate", rc, 0)
check("and the run still says PASS", "**PASS" in out, True)
check("while naming the coarse row", "Rows the clock cannot resolve" in out, True)
check("the section is printed once, not per comparison", out.count("`libm_fmod` — tick"), 1)

rc, out = run_gate({"libm_fmod": {"candidate": [61.0] * 5,
                                  "promoted": [61.0] * 5,
                                  "official": [58.0] * 5},
                    "launch": {"candidate": [69.3] * 5,
                               "promoted": [69.4] * 5,
                               "official": [70.0] * 5}}, 5)
check("a real breach still fails the gate", rc, 1)
check("and says so", "**BREACH" in out, True)

print(f"assert-perf-gate: {checks - failures}/{checks} checks passed")
sys.exit(1 if failures else 0)
