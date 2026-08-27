"""Browser execution speed across bench scenarios.

`benchmark-playwright.yml` measures what a consumer pays to GET to a running
test: pull, install, time-to-tests. This is the other half — how fast the
browser in the image then executes — so the two together describe the whole
chain rather than only its first leg.

Each scenario runs on its own hosted runner and the CPU model varies (three
models across twenty jobs in run 33038504763), so a single sample compares
machines as much as browsers. **The median over runs is what cancels that.**

An earlier version of this file also divided every metric by that run's own
`int_math`, on the theory that a pure-JS kernel stands in for the runner's
speed. Measured against ground truth — alpine vs official restricted to the
same CPU model, 8 and 7 samples — that normalization does nothing:

    ground truth                  geomean 1.158
    normalized      mean |log err| 0.0083
    raw, no normalizer            0.0085

Worse, on the alpine side `int_math` ANTI-correlates with the CPU-bound
kernels it is supposed to track (`layout` r=-0.98, `eval_rtt` r=-0.84), so at
low run counts it injected error rather than removing it. It is gone; the
median does the work.

Sample count is therefore load-bearing. Subsampling the same data:

    n=1   mean +19.9%  sd 13.1%   worst +52.2%
    n=3   mean +17.6%  sd  6.6%   worst +40.8%
    n=5   mean +16.2%  sd  1.2%   worst +19.4%
    n=10  mean +16.1%  sd  0.0%            (truth +15.8%)

so below MIN_RUNS the index reports nothing rather than a number that was
wrong by 25 points on a bad draw.
"""

import glob
import json
import math
import statistics

# Below this the geometric mean is a coin toss — see the table above.
MIN_RUNS = 5

# Fewer surviving metrics than this is not a geometric mean.
MIN_RATIOS = 4

# Wall-clock-bound kernels. `locator_click` is frame-quantized: it measured
# 3333.x ms on BOTH sides with a coefficient of variation of 0.0% across ten
# runs each, so it can express no difference between two browsers and only
# dilutes the index toward parity.
#
# Note the rule is "cannot discriminate", not "did not discriminate this time".
# `screenshot`, `js_alloc` and `libm_fmod` all came back ~1.000x against
# official — that is a finding, not a reason to drop them, and dropping a
# metric because it showed parity would bias every future index upward.
CLOCK_BOUND_METRICS = {"locator_click"}

# `libm_fmod` measures the C library rather than the browser build. Measured on
# firefox, musl runs it ~1.7x FASTER than glibc (50 vs 85 ms, 64 vs 110 ms)
# while a same-libc arm reads 0.99x; on chromium the same kernel comes back
# 1.001x. Keeping it answers "what does this image cost me"; dropping it
# answers "how good is this build".
LIBC_METRICS = {"libm_fmod"}
KEEP_LIBC_METRICS = True


def load_probes(pattern):
    """Read runtime-probe JSONs into {(scenario, browser): [{metric: median_ms}]}."""
    probes = {}
    for path in sorted(glob.glob(pattern)):
        try:
            record = json.load(open(path))
        except Exception:
            continue
        scenario, browser = record.get("target"), record.get("browser")
        metrics = {
            name: value["median_ms"]
            for name, value in (record.get("metrics") or {}).items()
            if isinstance(value, dict) and value.get("median_ms")
        }
        if not scenario or not browser or not metrics:
            continue
        probes.setdefault((scenario, browser), []).append(metrics)
    return probes


def profile(runs):
    """{metric: median milliseconds across runs}."""
    per_metric = {}
    for metrics in runs:
        for metric, value in metrics.items():
            if value:
                per_metric.setdefault(metric, []).append(value)
    return {m: statistics.median(v) for m, v in per_metric.items() if v}


def counts(metric):
    if metric in CLOCK_BOUND_METRICS:
        return False
    if metric in LIBC_METRICS and not KEEP_LIBC_METRICS:
        return False
    return True


def exec_index(probes, scenario, reference):
    """(percent delta, geometric standard deviation) against `reference`.

    Negative percent means faster than the reference. The second value is a
    MULTIPLICATIVE factor (>= 1), not a percentage — `exec_cell` turns it into a
    band. (None, None) when the scenario IS the reference, when either side has
    fewer than MIN_RUNS samples, or when too few metrics survive.
    """
    if scenario == reference:
        return None, None
    ratios = []
    for (name, browser), runs in probes.items():
        if name != scenario or len(runs) < MIN_RUNS:
            continue
        base_runs = probes.get((reference, browser))
        if not base_runs or len(base_runs) < MIN_RUNS:
            continue
        ours, theirs = profile(runs), profile(base_runs)
        for metric, value in ours.items():
            other = theirs.get(metric)
            if counts(metric) and value > 0 and other and other > 0:
                ratios.append(value / other)
    if len(ratios) < MIN_RATIOS:
        return None, None
    logs = [math.log(r) for r in ratios]
    geomean = math.exp(statistics.fmean(logs))
    # Sample stdev: the metrics are a sample of the kernels one could measure,
    # not the population of them, and `pstdev` understates (1.156 vs 1.164 on
    # the tracked fixture).
    gsd = math.exp(statistics.stdev(logs)) if len(logs) > 1 else 1.0
    return (geomean - 1) * 100, gsd


def _signed(percent):
    return f"{'−' if percent < 0 else '+'}{abs(percent):.0f}"


def exec_cell(percent, gsd):
    """`+16% [+0..+34]` — the value, then its +/-1 sigma band.

    The band is printed rather than the gsd itself because a geometric standard
    deviation is a multiplicative factor: rendering it as a percentage invites
    reading a symmetric +/-16 points when the real interval here is
    [+0.4%, +34.2%], asymmetric with the wider half on top. All three numbers
    carry the column's own sign convention, so the cell needs no legend.
    """
    if percent is None:
        return "—"
    cell = f"{_signed(percent)}%"
    if gsd and gsd > 1:
        geomean = percent / 100 + 1
        low, high = (geomean / gsd - 1) * 100, (geomean * gsd - 1) * 100
        cell += f" [{_signed(low)}..{_signed(high)}]"
    return cell
