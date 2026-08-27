"""Browser execution speed across bench scenarios, with the runner cancelled out.

`benchmark-playwright.yml` measures what a consumer pays to GET to a running
test: pull, install, time-to-tests. This is the other half — how fast the
browser in the image then executes — so the two together describe the whole
chain rather than only its first leg.

The bench runs one job per scenario and hosted runners hand out different CPU
models per job, so raw milliseconds compare machines, not browsers. Every metric
is therefore divided by that job's OWN `int_math` before any comparison: a
pure-JS integer kernel that touches no libc, no DOM and no allocator, and that
has measured flat across every build variant this repo has shipped (DCHECKs on
and off, PGO, ThinLTO). What survives the division is the browser.

Two deliberate choices about which metrics count:

- `int_math` is EXCLUDED. Normalized by itself both sides become x/x, so its
  ratio is exactly 1.0 and including it would only pull every scenario toward
  parity while shrinking the spread.
- `libm_fmod` is KEPT, and it is the one metric here that is NOT about the
  browser build. Measured on this repo's own artifacts, musl's fmod is ~1.7x
  FASTER than glibc's (50 vs 85 ms and 64 vs 110 ms across two runs), while a
  same-libc arm reads 0.99x — so the kernel really is libc-sensitive and the
  win is real. It stays because the consumer does get it, but it means an
  alpine row carries a libc effect on top of its browser effect: worth about
  -4% on a twelve-metric index. Drop it from KEEP_LIBC_METRICS if you want the
  index to describe only the build.

  (`runtime-probe.cjs` long claimed musl's fmod was ~2.1x SLOWER. That is
  contradicted by every cross-libc run this repo has recorded; the comment
  there has been corrected too.)
"""

import glob
import json
import math
import statistics

NORMALIZER = "int_math"

# Kernels whose result is dominated by the C library rather than by the browser
# build. Keeping them answers "what does this image cost me"; dropping them
# answers "how good is this build". See the module docstring for the numbers.
LIBC_METRICS = {"libm_fmod"}
KEEP_LIBC_METRICS = True

# Below this, a "geometric mean" is a couple of kernels that happened to
# survive. Report nothing rather than a figure nobody should quote.
MIN_RATIOS = 4


def load_probes(pattern):
    """Read runtime-probe JSONs into {(scenario, browser): [{metric: median_ms}]}.

    Every run is kept. `runs > 1` exists to survive a contended runner, and
    picking one sample by any rule throws that away — `normalized_profile`
    medians them instead.
    """
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
        if not scenario or not browser or not metrics.get(NORMALIZER):
            continue
        probes.setdefault((scenario, browser), []).append(metrics)
    return probes


def normalized_profile(runs):
    """{metric: median across runs of (metric / that run's normalizer)}.

    Normalizing INSIDE each run and medianing after is the order that matters:
    each run got its own machine, so a median of raw milliseconds would be a
    median over CPU models.
    """
    per_metric = {}
    for metrics in runs:
        divisor = metrics.get(NORMALIZER)
        if not divisor:
            continue
        for metric, value in metrics.items():
            if metric == NORMALIZER or not value:
                continue
            per_metric.setdefault(metric, []).append(value / divisor)
    return {m: statistics.median(v) for m, v in per_metric.items() if v}


def exec_index(probes, scenario, reference):
    """(percent delta, spread percent) for `scenario` against `reference`.

    Negative means faster than the reference. Returns (None, None) when the
    scenario IS the reference, or when either side lacks a usable probe.
    """
    if scenario == reference:
        return None, None
    ratios = []
    for (name, browser), runs in probes.items():
        if name != scenario:
            continue
        base_runs = probes.get((reference, browser))
        if not base_runs:
            continue
        ours = normalized_profile(runs)
        theirs = normalized_profile(base_runs)
        for metric, value in ours.items():
            if metric in LIBC_METRICS and not KEEP_LIBC_METRICS:
                continue
            other = theirs.get(metric)
            if value > 0 and other and other > 0:
                ratios.append(value / other)
    if len(ratios) < MIN_RATIOS:
        return None, None
    logs = [math.log(r) for r in ratios]
    geomean = math.exp(statistics.fmean(logs))
    gsd = math.exp(statistics.pstdev(logs)) if len(logs) > 1 else 1.0
    return (geomean - 1) * 100, (gsd - 1) * 100


def exec_cell(percent, gsd):
    if percent is None:
        return "—"
    cell = f"{'−' if percent < 0 else '+'}{abs(percent):.0f}%"
    if gsd is not None:
        cell += f" (gsd {gsd:.0f}%)"
    return cell
