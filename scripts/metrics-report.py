#!/usr/bin/env python3
"""Turn metrics/*.jsonl into the cost-vs-speed picture.

Four series, all against the same weekly axis:

    CI cost     runner-minutes, summed from job started->completed. `billable`
                is 0 on a public repo, so minutes — not dollars — is the unit.
    GHCR cost   bytes of the live tagged set at each point in time, from the
                sampled manifest sizes.
    time-to-tests   bench job start -> the test step starts. What a consumer
                waits through before a single test runs; mostly image pull.
    test time   the test step's own duration. What the browser build costs
                once everything is in place.

The last two are what the prebuilt images exist to move in opposite
directions: we pay time-to-tests down by making images bigger, which is
exactly why GHCR bytes belongs on the same chart.

Usage:
    metrics-report.py            # writes metrics/report.md + metrics/*.png
    metrics-report.py --text     # tables only, no charts
"""
import argparse
import collections
import datetime as dt
import glob
import json
import pathlib
import statistics
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "metrics"

# The step whose start divides "getting ready" from "testing", per job family.
# `whole` means the step is itself the entire measurement — an act scenario runs
# the pull AND the tests inside one step, so there is no boundary to read and no
# time-to-tests is reported for it rather than a made-up one.
TEST_STEPS = (
    ("run playwright tests", "split"),   # hosted bench
    ("run shard", "split"),              # conformance shards
    ("benchmark via act", "whole"),      # act bench
)


def load(kind, key=lambda r: r.get("id")):
    """Rows for one store, last write winning per key.

    The store is append-only and re-appends a row that was snapshotted while
    still in flight, so a run caught mid-build appears twice: once unfinished,
    once settled. Taking the last occurrence is what makes that correct.
    """
    latest = {}
    for path in sorted(glob.glob(str(OUT / kind / "*.jsonl"))):
        with open(path) as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                latest[key(row)] = row
    return list(latest.values())


def parse(ts):
    if not ts:
        return None
    return dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def week(ts):
    d = parse(ts)
    if not d:
        return None
    return (d - dt.timedelta(days=d.weekday())).strftime("%Y-%m-%d")


def duration_s(start, end):
    a, b = parse(start), parse(end)
    if not a or not b or b < a:
        return None
    return (b - a).total_seconds()


def test_step(job):
    """(started, completed, kind) of the step that runs the tests, or Nones."""
    for _number, name, _conclusion, started, completed in job.get("steps") or []:
        low = (name or "").lower()
        for hint, kind in TEST_STEPS:
            if hint in low:
                return started, completed, kind
    return None, None, None


def ci_cost(jobs):
    """Runner-minutes per week, split by workflow."""
    per_week = collections.defaultdict(lambda: collections.Counter())
    for job in jobs:
        w = week(job.get("started_at"))
        secs = duration_s(job.get("started_at"), job.get("completed_at"))
        if w and secs:
            per_week[w][job.get("workflow") or "?"] += secs / 60.0
    return per_week


def ghcr_cost(images):
    """Deduped bytes of the live tagged set as of each week.

    A blob is charged to the first week any manifest referenced it, because
    GHCR stores it once however many tags point at it. Summing each manifest's
    own total instead would count every shared base layer once per tag — for
    one package that inflated 3.6 GB of real storage into 25.4 GB.

    Only versions that still existed at snapshot time are in the data, so this
    is the surviving footprint, not what was live back then; anything deleted
    before the first snapshot is unrecoverable and simply absent.
    """
    first_seen, size_of = {}, {}
    for img in images:
        w = week(img.get("created_at"))
        if not w:
            continue
        for digest, size in img.get("layers") or []:
            size_of[digest] = size
            if digest not in first_seen or w < first_seen[digest]:
                first_seen[digest] = w
    events = collections.Counter()
    for digest, w in first_seen.items():
        events[w] += size_of[digest]
    running, series = 0, {}
    for w in sorted(events):
        running += events[w]
        series[w] = running
    return series, events


def pull_sizes(images):
    """tag-family -> [(created_at, bytes)] — what a consumer actually downloads.

    Distinct from occupancy: here the shared base layers SHOULD be counted in
    every image, because every consumer pulls them.
    """
    per_family = collections.defaultdict(list)
    for img in images:
        size = img.get("compressed_bytes")
        if not size:
            continue
        for tag in img.get("tags") or []:
            # sha-<40hex> is one tag per commit; the family is the package.
            family = img["package"] if tag.startswith("sha-") else f"{img['package']}:{tag}"
            per_family[family].append((img.get("created_at"), size))
    return per_family


def series_key(job):
    """The label a job's timings accumulate under, or None if it has no timings.

    Bench jobs are named `bench-<scenario>-<browsers>-<run>`; the run index is
    dropped so the five repeats of one scenario land in one median. Conformance
    shards are named `conformance-<browser> / shard (N)`; the shard number is
    dropped for the same reason.
    """
    name = job.get("name") or ""
    if name.startswith("bench-"):
        parts = name[len("bench-"):].rsplit("-", 2)
        return f"bench {parts[0]}/{parts[1]}" if len(parts) == 3 else None
    if name.startswith("conformance"):
        return "conformance " + name.split("/")[0].strip()[len("conformance-"):]
    return None


def bench_series(jobs):
    """label -> week -> {ttt, test} medians in seconds."""
    acc = collections.defaultdict(lambda: collections.defaultdict(
        lambda: {"ttt": [], "test": []}))
    for job in jobs:
        if job.get("conclusion") != "success":
            continue
        label = series_key(job)
        if not label:
            continue
        started, completed, kind = test_step(job)
        w = week(job.get("started_at"))
        if not started or not w:
            continue
        test = duration_s(started, completed)
        if test is not None:
            acc[label][w]["test"].append(test)
        # No pre-test boundary exists for a `whole` step, so nothing is recorded
        # rather than a zero that would read as "instant".
        if kind == "split":
            ttt = duration_s(job.get("started_at"), started)
            if ttt is not None:
                acc[label][w]["ttt"].append(ttt)
    return {
        label: {w: {k: statistics.median(v) for k, v in vals.items() if v}
                for w, vals in weeks.items()}
        for label, weeks in acc.items()
    }


def fmt_gb(n):
    return f"{n / 1024 ** 3:.1f} GB"


def write_report(jobs, runs, images, artifacts):
    cost = ci_cost(jobs)
    ghcr, weekly_add = ghcr_cost(images)
    bench = bench_series(jobs)
    lines = ["# CI + registry metrics", ""]

    span = [r.get("created_at") for r in runs if r.get("created_at")]
    lines += [
        f"- runs: **{len(runs)}** ({min(span)[:10]} -> {max(span)[:10]})" if span else "",
        f"- jobs: **{len(jobs)}**, "
        f"**{sum(sum(c.values()) for c in cost.values()) / 60:.0f}** runner-hours total",
        f"- tagged image versions priced: **{len(images)}**, "
        f"deduped GHCR footprint **{fmt_gb(max(ghcr.values()) if ghcr else 0)}** "
        f"(sum of per-image pull sizes: "
        f"{fmt_gb(sum(i.get('compressed_bytes') or 0 for i in images))})",
        f"- artifacts on record: **{len(artifacts)}**, "
        f"**{fmt_gb(sum(a.get('size_in_bytes') or 0 for a in artifacts))}**, "
        f"**{sum(1 for a in artifacts if a.get('expired'))}** already expired",
        "",
        "## Weekly cost",
        "",
        "| week | runner-hours | top workflow | GHCR added | GHCR live |",
        "|---|---:|---|---:|---:|",
    ]
    for w in sorted(set(cost) | set(ghcr)):
        wf = cost.get(w) or collections.Counter()
        top = wf.most_common(1)
        lines.append(
            f"| {w} | {sum(wf.values()) / 60:.1f} "
            f"| {top[0][0][:34] if top else '-'} "
            f"| {fmt_gb(weekly_add.get(w, 0))} "
            f"| {fmt_gb(ghcr.get(w, 0))} |"
        )

    lines += ["", "## Image pull size, per package", "",
              "| package | images | first | latest | min | max |",
              "|---|---:|---:|---:|---:|---:|"]
    for family, points in sorted(pull_sizes(images).items()):
        if ":" in family:
            continue  # moving tags repeat a sha-tagged digest already listed
        ordered = [size for _, size in sorted(points, key=lambda p: p[0] or "")]
        lines.append(
            f"| {family} | {len(ordered)} | {ordered[0] / 1024 ** 2:.0f} MB "
            f"| {ordered[-1] / 1024 ** 2:.0f} MB | {min(ordered) / 1024 ** 2:.0f} MB "
            f"| {max(ordered) / 1024 ** 2:.0f} MB |")

    lines += ["", "## Median seconds, per week", "",
              "| series | week | time-to-tests | test time |", "|---|---|---:|---:|"]
    for label in sorted(bench):
        for w in sorted(bench[label]):
            vals = bench[label][w]
            ttt = f"{vals['ttt']:.0f}" if "ttt" in vals else "-"
            test = f"{vals['test']:.0f}" if "test" in vals else "-"
            lines.append(f"| {label} | {w} | {ttt} | {test} |")

    (OUT / "report.md").write_text("\n".join(x for x in lines if x is not None) + "\n")
    print(f"wrote {OUT / 'report.md'}")
    return cost, ghcr, bench


def plot_lines(ax, weeks, bench, pick, field, title, ylabel):
    """One line per series `pick` accepts. A series needs two weeks to be a
    trend; a lone point is dropped rather than drawn as a flat segment."""
    drawn = 0
    for label in sorted(bench):
        if not pick(label):
            continue
        pts = [(weeks.index(w), v[field])
               for w, v in sorted(bench[label].items())
               if w in weeks and field in v]
        if len(pts) < 2:
            continue
        ax.plot([p[0] for p in pts], [p[1] for p in pts],
                marker="o", ms=3, lw=1.2, label=label)
        drawn += 1
    ax.set_title(title, fontsize=10)
    ax.set_ylabel(ylabel)
    if drawn:
        ax.legend(fontsize=6, loc="center left", bbox_to_anchor=(1.01, 0.5))


def write_charts(cost, ghcr, bench):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    weeks = sorted(set(cost) | set(ghcr) | {w for s in bench.values() for w in s})
    x = range(len(weeks))
    fig, (ax_cost, ax_ttt, ax_test) = plt.subplots(
        3, 1, figsize=(15, 12), sharex=True,
        gridspec_kw={"right": 0.72, "hspace": 0.32})

    ax_cost.bar(x, [sum(cost.get(w, {}).values()) / 60 for w in weeks],
                color="#4c72b0")
    ax_cost.set_ylabel("runner-hours / week", color="#4c72b0")
    ax_cost.set_title("CI cost and registry footprint", fontsize=10)
    ghcr_ax = ax_cost.twinx()
    ghcr_ax.plot(x, [ghcr.get(w, 0) / 1024 ** 3 for w in weeks],
                 color="#c44e52", marker="o", ms=3)
    ghcr_ax.set_ylabel("GHCR live GB", color="#c44e52")

    # The consumer-facing wait is the whole-suite `all` bench; the per-browser
    # and gyp variants repeat its shape and would only crowd the panel.
    plot_lines(ax_ttt, weeks, bench,
               lambda s: s.startswith("bench ") and s.endswith("/all")
               and "-gyp" not in s and "act-" not in s,
               "ttt", "Time-to-tests — what a consumer waits before test 1",
               "seconds (median)")
    # Test time is only comparable against the control that ran in the same
    # run, so this panel is the conformance pair, not the bench scenarios.
    plot_lines(ax_test, weeks, bench, lambda s: s.startswith("conformance "),
               "test", "Test time — our builds vs the glibc control",
               "seconds (median)")

    ax_test.set_xticks(list(x))
    ax_test.set_xticklabels(weeks, rotation=60, ha="right", fontsize=7)
    fig.savefig(OUT / "report.png", dpi=130, bbox_inches="tight")
    print(f"wrote {OUT / 'report.png'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", action="store_true", help="skip the charts")
    args = ap.parse_args()

    jobs = load("jobs")
    runs = load("runs", key=lambda r: (r.get("id"), r.get("run_attempt")))
    if not jobs:
        sys.exit("no jobs collected yet — run collect-metrics.py runs first")
    images = load("images", key=lambda r: (r.get("package"), r.get("digest")))
    cost, ghcr, bench = write_report(jobs, runs, images, load("artifacts"))
    if not args.text:
        write_charts(cost, ghcr, bench)


if __name__ == "__main__":
    main()
