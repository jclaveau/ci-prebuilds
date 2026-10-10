#!/usr/bin/env python3
"""Unit test for the perf-record report's per-iteration counters.

The report divided each `perf stat` count by the WHOLE loop's iteration rate
(kernel.json), while the counts cover only the stat pass, and the loop runs
at a different speed in every pass (ptrace under strace, the fp unwinder
under callers), unequally per arm. On 2026-09-27 that read 1.35x
instructions per iteration on a firefox build whose libxul SIMD was
byte-identical to its reference; the stat pass's own bracket read 0.997.

Literal files in a temp dir, no network, no perf.
"""
import importlib.util
import json
import pathlib
import sys
import tempfile

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location(
    "perf_record_report",
    pathlib.Path(__file__).resolve().parents[2] / "playwright" / "bench" / "perf-record-report.py",
)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

failures = 0
checks = 0


def check(label, got, want):
    global failures, checks
    checks += 1
    if got != want:
        print(f"FAIL: {label} — got {got!r}, wanted {want!r}", file=sys.stderr)
        failures += 1


STAT_20S = """### candidate / layout_reflow — hardware counters (a VM may refuse these)
       86332071358      instructions                     /                                                       (83.54%)
      20.000000000 seconds time elapsed
"""

# The stat bracket wins over the whole-loop rate: 60 iterations in 50 s.
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    (root / "candidate-layout_reflow-stat.txt").write_text(STAT_20S)
    (root / "candidate-layout_reflow-windows.txt").write_text(
        "cpu-clock 30.40 1 53\nstat 50.00 118 178\nstrace 15.20 223 245\n")
    (root / "candidate-layout_reflow-kernel.json").write_text(
        json.dumps({"iterations": 315, "seconds": 200}))
    rates = report.counter_rates(root, "candidate", "layout_reflow")
    check("iter from the stat bracket", rates["iter"], 1.2)
    check("instructions per second", rates["instructions"], 4316603567.9)

# No bracket (a run from before windows.txt existed): the whole-loop rate.
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    (root / "candidate-layout_reflow-stat.txt").write_text(STAT_20S)
    (root / "candidate-layout_reflow-kernel.json").write_text(
        json.dumps({"iterations": 315, "seconds": 200}))
    rates = report.counter_rates(root, "candidate", "layout_reflow")
    check("iter falls back to kernel.json", rates["iter"], 1.575)

# A windows.txt without a stat line (the pass failed): the whole-loop rate.
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    (root / "candidate-layout_reflow-stat.txt").write_text(STAT_20S)
    (root / "candidate-layout_reflow-windows.txt").write_text("cpu-clock 30.40 1 53\n")
    (root / "candidate-layout_reflow-kernel.json").write_text(
        json.dumps({"iterations": 315, "seconds": 200}))
    rates = report.counter_rates(root, "candidate", "layout_reflow")
    check("iter falls back without a stat line", rates["iter"], 1.575)

# A stat line cut short (the container died mid-pass): the whole-loop rate.
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    (root / "candidate-layout_reflow-stat.txt").write_text(STAT_20S)
    (root / "candidate-layout_reflow-windows.txt").write_text("stat 50.00 118\n")
    (root / "candidate-layout_reflow-kernel.json").write_text(
        json.dumps({"iterations": 315, "seconds": 200}))
    rates = report.counter_rates(root, "candidate", "layout_reflow")
    check("iter falls back on a truncated stat line", rates["iter"], 1.575)

print(f"{checks - failures}/{checks} checks passed")
sys.exit(1 if failures else 0)
