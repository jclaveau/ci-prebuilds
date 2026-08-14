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
import itertools
import json
import math
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


def week_of_iso(ts):
    """Monday of the week for a timestamp that may carry milliseconds.

    Claude Code writes `2026-08-05T07:31:10.749Z`, which the fixed-format
    parser above rejects; the CI stores never have sub-second precision.
    """
    if not ts or len(ts) < 10:
        return None
    try:
        d = dt.date.fromisoformat(ts[:10])
    except ValueError:
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


# Rates read from GitHub's docs on 2026-08-14. This repo is public and pays
# none of it — these are the counterfactual for the same workload run privately.
#
#   docs.github.com/en/billing/reference/actions-runner-pricing
#   docs.github.com/en/billing/concepts/product-billing/github-actions
#   docs.github.com/en/billing/concepts/product-billing/github-packages
#
# The January 2026 repricing cut runner rates ~40% and introduced a $0.002/min
# platform charge; per GitHub, "The new listed GitHub-runner rates include this
# charge", so 0.006 is the whole price and the fee is not added on top.
RUNNER_USD_PER_MINUTE = {"ubuntu-latest": 0.006}   # Linux 2-core x64
STORAGE_USD_PER_GB_MONTH = 0.25                    # artifacts + Packages, shared pool
INCLUDED_MINUTES = {"Free": 2000, "Pro": 3000, "Team": 3000, "Enterprise": 50000}

# The registry is exempt, not cheap: "Container image storage and bandwidth for
# the Container registry is currently free." The exemption is revocable —
# "you'll be informed at least one month in advance of any change to this
# policy" — so the report prices the exposure rather than treating it as zero
# forever. Applied at the Packages rate, since that is the pool it would join.
CONTAINER_REGISTRY_IS_FREE = True


def billed(jobs, bucket):
    """(bucket -> billed minutes, bucket -> USD, unpriced labels).

    Billing rounds *each job* up to a whole minute, so this is deliberately not
    the raw sum: across tens of thousands of mostly-short jobs the round-up is a
    real line item (+13%), not a rounding detail. Dollars are accumulated per
    job rather than by multiplying the total, so a future mixed-runner matrix
    prices correctly without touching this.
    """
    minutes, usd = collections.Counter(), collections.Counter()
    unpriced = collections.Counter()
    for job in jobs:
        secs = duration_s(job.get("started_at"), job.get("completed_at"))
        if not secs:
            continue  # never ran: skipped, or still in flight
        labels = job.get("labels") or []
        rate = next((RUNNER_USD_PER_MINUTE[x] for x in labels
                     if x in RUNNER_USD_PER_MINUTE), None)
        if rate is None:
            unpriced[tuple(labels)] += 1
            continue
        key = bucket(job)
        if not key:
            continue
        whole = math.ceil(secs / 60)
        minutes[key] += whole
        usd[key] += whole * rate
    return minutes, usd, unpriced


def session_cost(sessions, bucket):
    """(bucket -> USD, bucket -> output tokens, model -> USD) for the agents.

    The dollars are API-equivalent, not money spent: this work ran on a
    subscription, where these tokens are not invoiced per request. The figure
    is what the same conversations would have cost through the API, which is
    the only way to put agent effort and CI minutes on one axis. opencode's
    subscription-hosted models report cost 0, which is accurate rather than
    missing, so they contribute tokens and no dollars.
    """
    usd, out, per_model = collections.Counter(), collections.Counter(), collections.Counter()
    for row in sessions:
        key = bucket(row)
        if not key:
            continue
        usd[key] += row.get("usd") or 0
        out[key] += row.get("output") or 0
        per_model[f"{row.get('source')}/{row.get('model')}"] += row.get("usd") or 0
    return usd, out, per_model


def artifact_gb_months(artifacts):
    """GB-months of artifact storage, from each artifact's own retention.

    Charged on what was actually held: size times its own lifetime, not a
    snapshot of today's total. Artifacts that already expired still cost money
    while they existed, which is why the expired ones are counted too.
    """
    total = 0.0
    for art in artifacts:
        size = art.get("size_in_bytes") or 0
        held = duration_s(art.get("created_at"), art.get("expires_at"))
        if size and held:
            total += (size / 1024 ** 3) * (held / 86400) / 30.0
    return total


def carry_forward(series, weeks):
    """A stock's value at every week, held flat where nothing was published.

    Storage is a stock, not a rate: bytes published in June are still stored in
    July. Reading a gap as 0 — which is right for the runner-hours bars — made
    the curve collapse to zero and climb back. Carrying the level forward is
    what the data says; the markers still only sit on weeks that had an event.
    """
    out, last = [], 0
    for w in weeks:
        last = series.get(w, last)
        out.append(last)
    return out


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


def write_report(jobs, runs, images, artifacts, sessions):
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
        f"- agent requests: **{len(sessions)}**, "
        f"**${sum(r.get('usd') or 0 for r in sessions):,.0f}** API-equivalent "
        f"(subscription work — not money spent)",
        f"- artifacts on record: **{len(artifacts)}**, "
        f"**{fmt_gb(sum(a.get('size_in_bytes') or 0 for a in artifacts))}**, "
        f"**{sum(1 for a in artifacts if a.get('expired'))}** already expired",
        "",
        "## Weekly cost",
        "",
        "| week | runner-hours | top workflow | GHCR added | GHCR live |",
        "|---|---:|---|---:|---:|",
    ]
    table_weeks = sorted(set(cost) | set(ghcr))
    live = carry_forward(ghcr, table_weeks)
    for w, held in zip(table_weeks, live):
        wf = cost.get(w) or collections.Counter()
        top = wf.most_common(1)
        lines.append(
            f"| {w} | {sum(wf.values()) / 60:.1f} "
            f"| {top[0][0][:34] if top else '-'} "
            f"| {fmt_gb(weekly_add.get(w, 0))} "
            f"| {fmt_gb(held)} |"
        )

    minutes, dollars, unpriced = billed(
        jobs, lambda j: (j.get("started_at") or "")[:7])
    agent_usd, agent_out, agent_models = session_cost(
        sessions, lambda r: (r.get("ts") or "")[:7])
    gb_months = artifact_gb_months(artifacts)
    months = len(minutes) or 1
    lines += [
        "", "## What this would cost as a private repo", "",
        "Standard runners are free on public repos, so today this is all $0. "
        "Privately it is almost entirely Actions minutes, because the registry "
        "is exempt: *\"Container image storage and bandwidth for the Container "
        "registry is currently free.\"*", "",
        "| month | billed minutes | Actions $ | agent $ (API-equiv) | agent out Mtok |",
        "|---|---:|---:|---:|---:|",
    ]
    for month in sorted(set(minutes) | set(agent_usd)):
        lines.append(f"| {month} | {minutes.get(month, 0):,} "
                     f"| ${dollars.get(month, 0):,.0f} "
                     f"| ${agent_usd.get(month, 0):,.0f} "
                     f"| {agent_out.get(month, 0) / 1e6:.2f} |")
    total_min = sum(minutes.values())
    lines += [
        f"| **total** | **{total_min:,}** | **${sum(dollars.values()):,.0f}** "
        f"| **${sum(agent_usd.values()):,.0f}** "
        f"| **{sum(agent_out.values()) / 1e6:.2f}** |",
        "",
        f"Artifact storage: **{gb_months:,.1f} GB-months** "
        f"= **${gb_months * STORAGE_USD_PER_GB_MONTH:,.0f}** at "
        f"${STORAGE_USD_PER_GB_MONTH}/GB/month.",
        "",
        "Net of each plan's included minutes, per month averaged over the "
        f"{months} month(s) on record:", "",
        "| plan | included | billed over | $/month |", "|---|---:|---:|---:|",
    ]
    avg = total_min / months
    rate = RUNNER_USD_PER_MINUTE["ubuntu-latest"]
    for plan, included in INCLUDED_MINUTES.items():
        over = max(0, avg - included)
        lines.append(f"| {plan} | {included:,} | {over:,.0f} | ${over * rate:,.0f} |")
    live_gb = (max(ghcr.values()) if ghcr else 0) / 1024 ** 3
    lines += [
        "",
        f"Registry exposure if the exemption ends: **{live_gb:,.0f} GB** at "
        f"${STORAGE_USD_PER_GB_MONTH}/GB/month = "
        f"**${live_gb * STORAGE_USD_PER_GB_MONTH:,.0f}/month**, which would "
        "roughly double the bill. GitHub commits to one month's notice, so it "
        "is a watch item rather than a plan.",
    ]
    if unpriced:
        lines += ["", "Unpriced runner labels (not in the rate table): "
                  + ", ".join(f"`{lbl or '(none)'}` x{n}"
                              for lbl, n in unpriced.most_common(5))]

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
    _, weekly_usd, _ = billed(jobs, lambda j: week(j.get("started_at")))
    weekly_agent, _, _ = session_cost(sessions, lambda r: week_of_iso(r.get("ts")))
    return cost, ghcr, bench, weekly_usd, weekly_agent


def plot_lines(ax, weeks, bench, pick, field, title, ylabel):
    """One line per series `pick` accepts, broken wherever a week has no data.

    The y value is None on weeks with no measurement, which makes matplotlib
    lift the pen. Plotting only the weeks that HAVE data joins them with a
    straight segment, so the two-month stretch when nobody dispatched the
    benchmark read as a smooth trend between two unrelated campaigns — a
    different Playwright version and different images on either side of it.
    Markers still land only on real samples, so an isolated campaign shows as
    points rather than vanishing.
    """
    drawn = 0
    for label in sorted(bench):
        if not pick(label):
            continue
        series = bench[label]
        ys = [series[w][field] if w in series and field in series[w] else None
              for w in weeks]
        if sum(y is not None for y in ys) < 2:
            continue
        ax.plot(range(len(weeks)), ys, marker="o", ms=3, lw=1.2, label=label)
        drawn += 1
    ax.set_title(title, fontsize=10)
    ax.set_ylabel(ylabel)
    if drawn:
        ax.legend(fontsize=6, loc="center left", bbox_to_anchor=(1.01, 0.5))


def write_charts(cost, ghcr, bench, weekly_usd, weekly_agent, since=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    # EVERY week between the first and last, not only the ones carrying data.
    # Plotting just the populated weeks makes the axis ordinal, so the seven
    # months when nothing happened rendered the same width as a single busy
    # week — a slope read off that axis means nothing. Empty weeks now cost
    # real horizontal space, which is what they did in life.
    present = (set(cost) | set(ghcr) | set(weekly_usd) | set(weekly_agent)
               | {w for s in bench.values() for w in s})
    first, last = max(min(present), since or ""), max(present)
    weeks, cursor = [], dt.date.fromisoformat(first)
    while cursor <= dt.date.fromisoformat(last):
        weeks.append(cursor.strftime("%Y-%m-%d"))
        cursor += dt.timedelta(days=7)
    x = range(len(weeks))
    fig, (ax_cost, ax_ghcr, ax_ttt, ax_test) = plt.subplots(
        4, 1, figsize=(15, 15), sharex=True,
        gridspec_kw={"right": 0.72, "hspace": 0.34})

    # Actions cost. The bars are what a private repo would be invoiced that
    # week; the line is the running total, which is the question "what has this
    # project cost so far" and does not fall just because a week was quiet.
    ci = [weekly_usd.get(w, 0) for w in weeks]
    agent = [weekly_agent.get(w, 0) for w in weeks]
    ax_cost.bar([i - 0.2 for i in x], ci, width=0.4, color="#4c72b0",
                label="Actions (private-repo counterfactual)")
    ax_cost.bar([i + 0.2 for i in x], agent, width=0.4, color="#dd8452",
                label="coding agents (API-equivalent)")
    ax_cost.set_ylabel("$ / week")
    ax_cost.set_title(
        "What this project costs — neither is money actually spent: the repo "
        "is public and the agents ran on a subscription", fontsize=10)
    ax_cost.legend(fontsize=7, loc="upper left")
    cum_ax = ax_cost.twinx()
    cum_ax.plot(x, list(itertools.accumulate(a + b for a, b in zip(ci, agent))),
                color="#55a868", lw=1.6)
    cum_ax.set_ylabel("cumulative $ (both)", color="#55a868")
    cum_ax.set_ylim(bottom=0)

    # Registry: bytes on the left, what they WOULD cost on the right. The two
    # axes are the same series rescaled, because the registry is exempt today
    # and the dollar figure is only the exposure if that policy ends.
    held_gb = [b / 1024 ** 3 for b in carry_forward(ghcr, weeks)]
    ax_ghcr.plot(x, held_gb, color="#c44e52", lw=1.6)
    sampled = [i for i, w in enumerate(weeks) if w in ghcr]
    ax_ghcr.plot(sampled, [held_gb[i] for i in sampled],
                 color="#c44e52", ls="none", marker="o", ms=3.5)
    ax_ghcr.set_ylabel("GHCR live GB", color="#c44e52")
    ax_ghcr.set_ylim(bottom=0)
    ax_ghcr.set_title(
        "Registry footprint — free today; right axis is the exposure "
        "if the exemption ends", fontsize=10)
    usd_ax = ax_ghcr.twinx()
    usd_ax.set_ylim(0, max(held_gb or [0]) * STORAGE_USD_PER_GB_MONTH * 1.05 or 1)
    # Escaped: a pair of bare $ in a matplotlib label is parsed as mathtext and
    # the text comes out italic with the dollar signs eaten.
    usd_ax.set_ylabel(
        rf"\$/month at \${STORAGE_USD_PER_GB_MONTH}/GB", color="#8172b2")

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

    # One label per month or the axis is unreadable at ~44 weeks.
    ticks = [i for i, w in enumerate(weeks) if i % 4 == 0]
    ax_test.set_xticks(ticks)
    ax_test.set_xticklabels([weeks[i] for i in ticks],
                            rotation=60, ha="right", fontsize=7)
    fig.savefig(OUT / "report.png", dpi=130, bbox_inches="tight")
    print(f"wrote {OUT / 'report.png'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", action="store_true", help="skip the charts")
    ap.add_argument("--since", metavar="YYYY-MM-DD",
                    help="start the chart here. The axis is time-proportional, "
                         "so a long dormant stretch squeezes the active weeks "
                         "into a corner; this zooms without distorting it.")
    args = ap.parse_args()

    jobs = load("jobs")
    sessions = load("sessions", key=lambda r: r.get("key"))
    runs = load("runs", key=lambda r: (r.get("id"), r.get("run_attempt")))
    if not jobs:
        sys.exit("no jobs collected yet — run collect-metrics.py runs first")
    images = load("images", key=lambda r: (r.get("package"), r.get("digest")))
    cost, ghcr, bench, weekly_usd, weekly_agent = write_report(
        jobs, runs, images, load("artifacts"), sessions)
    if not args.text:
        write_charts(cost, ghcr, bench, weekly_usd, weekly_agent, args.since)


if __name__ == "__main__":
    main()
