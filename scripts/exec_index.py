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

- `int_math` is EXCLUDED. Normalized by itself its ratio is 1.0 by
  construction, so including it would only pull every scenario toward parity.
- `libm_fmod` is KEPT. musl's fmod really is ~2x glibc's; that is a cost the
  consumer pays, not an artefact of the instrument.
"""

import glob
import json
import math
import statistics

NORMALIZER = "int_math"

# Below this, a "geometric mean" is a couple of kernels that happened to
# survive. Report nothing rather than a figure nobody should quote.
MIN_RATIOS = 4


def load_probes(pattern):
    """Read runtime-probe JSONs into {(scenario, browser): {metric: median_ms}}.

    Several runs of one scenario collide on the same key; the one whose
    normalizer is fastest wins, i.e. the least contended runner.
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
        previous = probes.get((scenario, browser))
        if previous is None or metrics[NORMALIZER] < previous[NORMALIZER]:
            probes[(scenario, browser)] = metrics
    return probes


def exec_index(probes, scenario, reference):
    """(percent delta, spread percent) for `scenario` against `reference`.

    Negative means faster than the reference. Returns (None, None) when the
    scenario IS the reference, or when either side lacks a usable probe.
    """
    if scenario == reference:
        return None, None
    ratios = []
    for (name, browser), metrics in probes.items():
        if name != scenario:
            continue
        base = probes.get((reference, browser))
        if not base or not base.get(NORMALIZER):
            continue
        for metric, value in metrics.items():
            if metric == NORMALIZER or not value or not base.get(metric):
                continue
            ours = value / metrics[NORMALIZER]
            theirs = base[metric] / base[NORMALIZER]
            if ours > 0 and theirs > 0:
                ratios.append(ours / theirs)
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
