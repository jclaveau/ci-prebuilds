#!/usr/bin/env python3
"""Render the benchmark run summary from this run's job timings and artifacts.

A file rather than a heredoc inside `benchmark-playwright.yml` because GitHub
treats a step's whole `run:` block as a template and rejects the workflow past
~21k characters — "Exceeded max expression length 21000", raised at parse time,
so nothing runs and no job appears. The block was already at 24k on main and one
added column tipped it over. Keeping this here means the ceiling is gone rather
than moved.

Reads: jobs.ndjson (written by the caller, which needs `${{ }}` expressions the
python does not), act-results/, install-dl/, runtime-probe/, sizes.tsv.
Writes: $GITHUB_STEP_SUMMARY.
"""

import json, os, glob, statistics, urllib.parse
from collections import defaultdict
from datetime import datetime

def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))

def dur(a, b):
    return (ts(b) - ts(a)).total_seconds() if a and b else None

def fmt(x):
    return "—" if x is None else f"{x:.0f}s"

INSTALL = {"Install project deps", "Install Playwright browsers + system deps",
           "Install node-gyp toolchain", "Install docker"}
jobs = [json.loads(line) for line in open("jobs.ndjson") if line.strip()]

# scenario -> compressed image size (MB), from the Compute-image-sizes step (baseline has none).
SIZE = {}
try:
    for line in open("sizes.tsv"):
        sc, mb = line.rstrip("\n").split("\t")
        SIZE[sc] = int(mb)
except FileNotFoundError:
    pass

def size_cell(sc):
    mb = SIZE.get(sc)
    return "—" if mb is None else f"{mb}&nbsp;MB"

# (scenario, mode) -> [install download MB per run]; hosted from artifact files, act from JSON.
INSTALL_DL = defaultdict(list)
for d in sorted(glob.glob("install-dl/install-dl-*")):
    key = os.path.basename(d)[len("install-dl-"):]
    parts = key.rsplit("-", 2)
    if len(parts) != 3:
        continue
    sc, mode, _run = parts
    try:
        with open(os.path.join(d, "install-dl-mb.txt")) as fh:
            INSTALL_DL[(sc, mode)].append(int(fh.read().strip()))
    except (FileNotFoundError, ValueError):
        pass

def full_dl_cell(sc, mode, dl_overrides=None):
    # full dl = compressed image pull + bytes downloaded during install steps; baseline has no
    # image so it's pure install dl.
    dl_list = dl_overrides if dl_overrides is not None else INSTALL_DL.get((sc, mode), [])
    dl_mb = (sum(dl_list) // len(dl_list)) if dl_list else None
    img_mb = SIZE.get(sc, 0)
    if dl_mb is None and not img_mb:
        return "—"
    total = (dl_mb or 0) + (img_mb or 0)
    return f"{total}&nbsp;MB"

agg = defaultdict(lambda: defaultdict(list))   # (scenario, mode) -> metric -> [values per run]
oks = defaultdict(lambda: [0, 0])              # (scenario, mode) -> [successful, total]
seen = set()
for j in jobs:
    name = j.get("name", "")
    if not name.startswith("bench-") or name.startswith("bench-act-"):
        continue
    parts = name[len("bench-"):].rsplit("-", 2)   # scenario, mode, run
    if len(parts) != 3:
        continue
    scenario, mode, _run = parts
    steps = j.get("steps") or []
    by = {s.get("name"): s for s in steps}
    test = by.get("Run Playwright tests", {})
    init = by.get("Initialize containers", {})
    install = sum(
        d for s in steps if s.get("name") in INSTALL
        for d in [dur(s.get("started_at"), s.get("completed_at"))] if d is not None
    )
    key = (scenario, mode)
    seen.add(key)
    vals = {
        "pull": dur(init.get("started_at"), init.get("completed_at")),
        "install": install,
        "ttt": dur(j.get("started_at"), test.get("started_at")),
        "test": dur(test.get("started_at"), test.get("completed_at")),
        "total": dur(j.get("started_at"), j.get("completed_at")),
    }
    for k, v in vals.items():
        if v is not None:
            agg[key][k].append(v)
    oks[key][1] += 1
    oks[key][0] += 1 if j.get("conclusion") == "success" else 0

# Student's t (two-sided 95%) by df = n-1; falls back to z for large n.
T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
       7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228}

def mean_of(xs):
    xs = [x for x in xs if x is not None]
    return statistics.fmean(xs) if xs else None

def stats95(xs):
    # (mean, sample SD (n-1), 95% margin of error) — SD/MoE are None when n < 2
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    m = statistics.fmean(xs)
    if len(xs) < 2:
        return (m, None, None)
    s = statistics.stdev(xs)
    t = T95.get(len(xs) - 1, 1.96)
    return (m, s, t * s / len(xs) ** 0.5)

def ttt_cell(xs):
    st = stats95(xs)
    if st is None:
        return "—", None
    m, sd, moe = st
    return (f"{m:.0f}s" if moe is None else f"{m:.0f}s ± {moe:.0f}s"), m

def cv(xs):
    st = stats95(xs)
    return (st[1] / st[0] * 100) if (st and st[1] is not None and st[0]) else None

def delta_cell(m, base, cv_xs, base_xs=None):
    # Δ seconds (carrying the CV of the underlying metric) + Δ %
    if m is None or not base:
        return "—", "—"
    d = m - base
    ds = f"{'−' if d < 0 else '+'}{abs(d):.0f}s"
    c = cv(cv_xs)
    if c is not None:
        ds += f" (CV {c:.0f}%)"
    # Flag a Δ that is smaller than the noise of the two means it subtracts.
    # `pull` dominates time-to-tests for every prebuilt image and is registry
    # variance, not image property: near-identical images measured 22s and 42s
    # in the same run at n=3. Without this marker those gaps read as findings —
    # they were quoted as one before this was added.
    a = stats95(cv_xs)
    b = stats95(base_xs) if base_xs else None
    if a and b and a[2] is not None and b[2] is not None:
        noise = (a[2] ** 2 + b[2] ** 2) ** 0.5
        if abs(d) < noise:
            ds += " n.s."
    return ds, f"{'−' if d < 0 else '+'}{abs(d / base * 100):.0f}%"

# Per-Δ-cell shields.io badge: the label IS the value, the color encodes sign + magnitude
# interpolated grey↔green (gains) or grey↔red (losses), normalized to the column's extremes.
# GitHub step-summary markdown strips inline `style`/`bgcolor` from <td> but keeps <img>, so
# rendering color via a static-badge endpoint is the only way to get true RGB nuance here.
_BADGE = "https://img.shields.io/static/v1"
_GREY, _GREEN, _RED = (238, 238, 238), (46, 204, 113), (231, 76, 60)
def _mix(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
def badge(value, vmin, vmax, label):
    if not label or label == "—":
        return label or "—"
    color = _GREY
    if value is not None:
        if value < 0 and vmin is not None and vmin < 0:
            color = _mix(_GREY, _GREEN, max(0.0, min(1.0, value / vmin)))
        elif value > 0 and vmax is not None and vmax > 0:
            color = _mix(_GREY, _RED, max(0.0, min(1.0, value / vmax)))
    q = urllib.parse.urlencode({"label": "", "message": label,
                                "color": "{:02x}{:02x}{:02x}".format(*color),
                                "style": "for-the-badge"})
    return f'<img src="{_BADGE}?{q}" alt="{label}">'

def col_range(values):
    vs = [v for v in values if v is not None]
    return (min(vs), max(vs)) if vs else (None, None)

# Tables are split into "without gyp" and "with gyp" so each comparison has its own reference.
NO_GYP = ["baseline", "official",
          "ubuntu-dood", "ubuntu-dind", "alpine-dood", "alpine-dind"]
GYP    = ["baseline-gyp", "official-gyp",
          "ubuntu-dood-gyp", "ubuntu-dind-gyp", "alpine-dood-gyp", "alpine-dind-gyp"]
LABEL = {
    "baseline": "manual install",
    "baseline-gyp": "manual install + gyp",
    "official": "official pw container",
    "official-gyp": "official pw container + gyp",
    "ubuntu-dood": "ubuntu-dood-playwright",
    "ubuntu-dood-gyp": "ubuntu-dood-playwright-gyp",
    "ubuntu-dind": "ubuntu-dind-playwright",
    "ubuntu-dind-gyp": "ubuntu-dind-playwright-gyp",
    "alpine-dood": "alpine-dood-playwright",
    "alpine-dood-gyp": "alpine-dood-playwright-gyp",
    "alpine-dind": "alpine-dind-playwright",
    "alpine-dind-gyp": "alpine-dind-playwright-gyp",
}

# ---- runtime probe: browser execution speed, normalized per job ----
# `Test run` above fetches a live site, so it is mostly internet. This is
# the other half of what a consumer pays. The normalization — and WHY
# int_math is the divisor, why it is excluded from the index and why
# libm_fmod is not — lives in scripts/exec_index.py, which
# tests/conformance/test-exec-index.py exercises directly.
from exec_index import load_probes, exec_index, exec_cell
probe = load_probes("runtime-probe/*.json")

def table(mode, order_list, ref, title):
    """Hosted table (HTML). Per-cell rgba background — each duration AND each Δ column gets
    its own per-table gradient (deltas are the most important signal)."""
    # Hosted = ubuntu-latest VM, so the baseline label gets a `vm +` prefix here (act tables
    # use `LABEL` directly because their baseline is a Docker image, not a VM).
    L = {**LABEL, "baseline": "vm + manual install", "baseline-gyp": "vm + manual install + gyp"}
    bs = stats95(agg[(ref, mode)]["ttt"])
    base = bs[0] if bs else None
    rows = []
    for sc in order_list:
        key = (sc, mode)
        if key not in seen:
            continue
        cell_str, ttt_m = ttt_cell(agg[key]["ttt"])
        if sc == ref or ttt_m is None or not base:
            d_str, p_str, d_num, p_num = "—", "—", None, None
        else:
            d_str, p_str = delta_cell(ttt_m, base, agg[key]["ttt"], agg[(ref, mode)]["ttt"])
            d_num = ttt_m - base
            p_num = d_num / base * 100
        ok, n = oks[key]
        x_num, x_gsd = exec_index(probe, sc, ref)
        rows.append({
            "sc": sc,
            "pull":    mean_of(agg[key]["pull"]),
            "install": mean_of(agg[key]["install"]),
            "ttt":     ttt_m,
            "test":    mean_of(agg[key]["test"]),
            "total":   mean_of(agg[key]["total"]),
            "d_num": d_num, "p_num": p_num,
            "x_num": x_num, "x": exec_cell(x_num, x_gsd),
            "cell_str": cell_str, "d": d_str, "p": p_str, "ok": ok, "n": n,
        })
    R = {k: col_range([r[k] for r in rows]) for k in ("d_num", "p_num", "x_num")}
    out = [
        f"### {title}",
        "",
        '<table>',
        '<thead><tr>'
        '<th width="240">Scenario</th><th width="60">Runs OK</th><th width="90">Image&nbsp;size</th>'
        '<th>pull</th><th>install</th><th width="90">full&nbsp;dl&nbsp;size</th><th>time to tests</th>'
        '<th>Test run</th>'
        '<th width="130">Δ&nbsp;execution&nbsp;%</th>'
        '<th>Total</th>'
        '<th>Δ</th>'
        '<th>Δ %</th>'
        '</tr></thead>',
        '<tbody>',
    ]
    for r in rows:
        out.append(
            f'<tr>'
            f'<td>{L.get(r["sc"], r["sc"])}</td>'
            f'<td>{r["ok"]}/{r["n"]}</td>'
            f'<td>{size_cell(r["sc"])}</td>'
            f'<td>{fmt(r["pull"])}</td>'
            f'<td>{fmt(r["install"])}</td>'
            f'<td>{full_dl_cell(r["sc"], mode)}</td>'
            f'<td>{r["cell_str"]}</td>'
            f'<td>{fmt(r["test"])}</td>'
            f'<td>{badge(r["x_num"], *R["x_num"], r["x"])}</td>'
            f'<td>{fmt(r["total"])}</td>'
            f'<td>{badge(r["d_num"], *R["d_num"], r["d"])}</td>'
            f'<td>{badge(r["p_num"], *R["p_num"], r["p"])}</td>'
            f'</tr>'
        )
    out.append('</tbody></table>')
    return "\n".join(out)

# ---- act scenarios, from uploaded artifacts (self-measured time-to-tests) ----
act = defaultdict(lambda: defaultdict(list))
act_ok = defaultdict(lambda: [0, 0])
act_seen = set()
for af in sorted(glob.glob("act-results/*.json")):
    try:
        rec = json.load(open(af))
    except Exception:
        continue
    sc, mode = rec.get("scenario"), rec.get("mode")
    if not sc or not mode:
        continue
    key = (sc, mode)
    act_seen.add(key)
    for k in ("pull", "install", "ttt", "test", "total", "install_dl_mb", "disk_mb"):
        if rec.get(k) is not None:
            act[key][k].append(rec[k])
    act_ok[key][1] += 1
    act_ok[key][0] += 1 if rec.get("rc") == 0 else 0

def act_table(mode, order_list, ref, title):
    """Act table (HTML). Per-cell rgba background — duration cells AND each Δ column get their
    own per-table gradients. Cold (Δ) and warm (Δ warm) can rank differently in act.
    `baseline`/`baseline-gyp` rows are NOT measured in act (>15 min apt unpack nested in DinD)
    — they're rendered as a placeholder row with `> 15mn` in `install` and `—` elsewhere, and
    the Δ reference is the official PW container, not baseline."""
    bkey = (ref, mode)
    bs = stats95(act[bkey]["ttt"])
    base = bs[0] if bs else None
    # Warm ref = the table's cold ref (official PW container for no-gyp tables, official +
    # node-gyp for gyp tables) — what the user pays on a warm run when the image is cached.
    warm_base = mean_of(act[bkey]["install"])
    disk_base = mean_of(act[bkey].get("disk_mb", []))
    rows = []
    for sc in order_list:
        if sc in ("baseline", "baseline-gyp"):
            rows.append({
                "sc": sc, "pull": None, "install": None, "ttt": None,
                "test": None, "total": None, "disk": None,
                "d_num": None, "p_num": None, "wd_num": None, "wp_num": None, "du_num": None,
                "cell_str": "—", "d": "—", "p": "—", "wd": "—", "wp": "—", "du": "—",
                "ok": 0, "n": 0, "stub": True,
            })
            continue
        key = (sc, mode)
        if key not in act_seen:
            continue
        cell_str, ttt_m = ttt_cell(act[key]["ttt"])
        warm_m = mean_of(act[key]["install"])
        disk_m = mean_of(act[key].get("disk_mb", []))
        if sc == ref:
            d, p, wd, wp, du = "—", "—", "—", "—", "—"
            d_num = p_num = wd_num = wp_num = du_num = None
        else:
            d, p = delta_cell(ttt_m, base, act[key]["ttt"], act[bkey]["ttt"])
            wd, wp = delta_cell(warm_m, warm_base, act[key]["install"], act[bkey]["install"])
            d_num  = (ttt_m - base) if (ttt_m is not None and base) else None
            p_num  = (d_num / base * 100) if (d_num is not None and base) else None
            wd_num = (warm_m - warm_base) if (warm_m is not None and warm_base) else None
            wp_num = (wd_num / warm_base * 100) if (wd_num is not None and warm_base) else None
            du_num = ((disk_m - disk_base) / disk_base * 100
                      if (disk_m is not None and disk_base) else None)
            du = (f"{'−' if du_num < 0 else '+'}{abs(du_num):.0f}%"
                  if du_num is not None else "—")
        ok, n = act_ok[key]
        rows.append({
            "sc": sc,
            "pull":    mean_of(act[key]["pull"]),
            "install": warm_m,
            "ttt":     ttt_m,
            "test":    mean_of(act[key]["test"]),
            "total":   mean_of(act[key]["total"]),
            "disk":    disk_m,
            "d_num": d_num, "p_num": p_num, "wd_num": wd_num, "wp_num": wp_num,
            "du_num": du_num,
            "cell_str": cell_str, "d": d, "p": p, "wd": wd, "wp": wp, "du": du,
            "ok": ok, "n": n, "stub": False,
        })
    R = {k: col_range([r[k] for r in rows]) for k in
         ("d_num", "p_num", "wd_num", "wp_num", "du_num")}
    out = [
        f"### {title}",
        "",
        '<table>',
        '<thead><tr>'
        '<th width="240">Scenario</th><th width="60">Runs OK</th><th width="90">Image&nbsp;size</th>'
        '<th>pull</th><th>install</th><th width="90">full&nbsp;dl&nbsp;size</th><th>time to tests</th>'
        '<th>Test run</th><th>Total</th>'
        '<th width="90">disk&nbsp;usage</th>'
        '<th>Δ disk %</th>'
        '<th>Δ</th>'
        '<th>Δ %</th>'
        '<th>Δ warm</th>'
        '<th>Δ % warm</th>'
        '</tr></thead>',
        '<tbody>',
    ]
    for r in rows:
        install_str = "&gt; 15mn" if r["stub"] else fmt(r["install"])
        runs_str = "—" if r["stub"] else f'{r["ok"]}/{r["n"]}'
        full_dl_str = "—" if r["stub"] else full_dl_cell(r["sc"], mode, act[(r["sc"], mode)].get("install_dl_mb", []))
        disk_str = "—" if r["disk"] is None else f'{int(r["disk"])}&nbsp;MB'
        out.append(
            f'<tr>'
            f'<td>{LABEL.get(r["sc"], r["sc"])}</td>'
            f'<td>{runs_str}</td>'
            f'<td>{size_cell(r["sc"])}</td>'
            f'<td>{fmt(r["pull"])}</td>'
            f'<td>{install_str}</td>'
            f'<td>{full_dl_str}</td>'
            f'<td>{r["cell_str"]}</td>'
            f'<td>{fmt(r["test"])}</td>'
            f'<td>{fmt(r["total"])}</td>'
            f'<td>{disk_str}</td>'
            f'<td>{badge(r["du_num"], *R["du_num"], r["du"])}</td>'
            f'<td>{badge(r["d_num"],  *R["d_num"],  r["d"])}</td>'
            f'<td>{badge(r["p_num"],  *R["p_num"],  r["p"])}</td>'
            f'<td>{badge(r["wd_num"], *R["wd_num"], r["wd"])}</td>'
            f'<td>{badge(r["wp_num"], *R["wp_num"], r["wp"])}</td>'
            f'</tr>'
        )
    out.append('</tbody></table>')
    return "\n".join(out)

parts = [
    "## Playwright cold-start benchmark",
    "",
    f"Each scenario ran **{int(os.environ.get('BENCH_RUNS', '1'))}×** "
    "(configure via the `runs` workflow_dispatch input; 1 = fast iteration, 10 = full 95% CI). "
    "Δ columns are point estimates when n=1; mean ± 95% MoE via Student's t when n≥2. "
    "**Time-to-tests** = job start → the moment `playwright test` begins (queue excluded). "
    "*Image pull* is the `Initialize containers` step; *Install* is the runtime dep/browser "
    "install that the prebuilt images bake in. Δ is the time earned vs the table's reference row "
    "(hosted → manual install; act → official PW container); − = faster.",
    "",
    "**Reading the CV** (rule of thumb): ≤5% tight · ≤10% good · 10–20% noisy · "
    ">20% unreliable — treat the mean with caution.",
    "",
    table("chromium", NO_GYP, "baseline",     "Via GHA — Chromium only — without gyp"),
    "",
    table("chromium", GYP,    "baseline-gyp", "Via GHA — Chromium only — with gyp"),
    "",
    table("all", NO_GYP, "baseline",     "Via GHA — All browsers — without gyp"),
    "",
    table("all", GYP,    "baseline-gyp", "Via GHA — All browsers — with gyp"),
    "",
    act_table("chromium", NO_GYP, "official",     "Via act — Chromium only — without gyp"),
    "",
    act_table("chromium", GYP,    "official-gyp", "Via act — Chromium only — with gyp"),
    "",
    act_table("all", NO_GYP, "official",     "Via act — All browsers — without gyp"),
    "",
    act_table("all", GYP,    "official-gyp", "Via act — All browsers — with gyp"),
    "",
    "_**Tables are split by gyp**: *hosted without-gyp* compares each scenario to the **vm + "
    "manual install** row; *hosted with-gyp* to **vm + manual install + gyp**. *Act* tables "
    "compare to the **official pw container** (`/-gyp`) — a from-scratch manual install inside "
    "nested act+DinD pays >15 min for the apt unpack, so we don't run it and the row shows "
    "`> 15mn` as a placeholder. Each Δ value is rendered as a shields.io badge whose color "
    "interpolates grey↔green for gains and grey↔red for losses, normalized to that column's "
    "`[min, max]` within the table. In act tables, Δ (cold) and Δ warm (install only) are "
    "colored independently so their rankings can diverge._ "
    "_Note that **act-in-DinD writes are noticeably slower than native** (overlayfs on overlayfs "
    "through the hosted runner's docker), so any apt-install cell timing is the worst-case ceiling "
    "— a user running `act` locally on their own SSD would see less of the apt-unpack cost._ "
    "_**Image size** is the image's compressed (amd64) pull size — also the size delta vs the "
    "`manual install` baseline, which pulls no image (`—`). **`full dl size`** = `Image size` "
    "+ bytes downloaded during the `install` steps (pnpm tarballs, apt debs, Playwright "
    "browser CDN), measured via `/proc/net/dev:eth0` rx delta between job start and just "
    "before tests; for `manual install` rows there's no image so it equals the install dl. "
    "**`official pw container + gyp`** is the "
    "official image with the node-gyp toolchain added at runtime (`apt install build-essential`, "
    "counted in *Install*) — the cost `…-playwright-gyp` bakes away; the `manual install` baseline "
    "already has a usable toolchain (gcc/g++/make ship on `ubuntu-latest`), so its gyp cost is ~0. "
    "The `…-playwright-gyp` rows are the same image **plus the node-gyp toolchain** "
    "(build-essential / build-base); compare each slim row with its `-gyp` twin to read the "
    "compiler's pull cost. "
    "**Δ execution %** is the other half of the chain: `pull`/`install`/`time to tests` "
    "are what a consumer pays to REACH a running test, and this is how fast the browser "
    "then executes. It comes from `playwright/bench/runtime-probe.cjs`, which serves its "
    "own page from `127.0.0.1` (so, unlike *Test run*, no CDN is in the measurement) and "
    "times launch, navigation, layout, screenshot and a set of in-page kernels. Each "
    "scenario gets its own runner and hosted CPU models differ 20-30%, so every metric is "
    "divided by that job's own `int_math` — a pure-JS kernel touching no libc, no DOM and "
    "no allocator — before the geometric mean against the reference row. With `runs > 1` "
    "each metric is normalized INSIDE its own run and the runs are then medianed, so a "
    "contended runner cannot move the figure. `gsd` is the spread of the underlying "
    "per-metric ratios, and a wide one means the metrics disagree and the single number "
    "should not be quoted alone. Negative is faster. One caveat worth carrying: "
    "`libm_fmod` is a C-library kernel, not a browser one, and musl measures ~1.7x FASTER "
    "there — so an alpine row's index includes a libc gain of roughly 4% that has nothing "
    "to do with how the browser was built. "
    "`alpine-dood-playwright` and `alpine-dind-playwright` carry all three browsers "
    "(chromium, firefox and webkit, all built from source against musl), so the "
    "*All browsers* tables measure the same work on every row. The **act** tables run each "
    "image as a local `nektos/act` runner, self-measured from `act` start; their *Image pull* "
    "also includes act's own start-up overhead, so it isn't directly comparable to the hosted "
    "`Initialize containers` time. The **warm** Δ columns exclude the pull (= install only) — "
    "what you actually wait on repeat local runs, where act has the image cached._",
]
text = "\n".join(parts) + "\n"
with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
    f.write(text)
print(text)
