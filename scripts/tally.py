#!/usr/bin/env python3
"""One-screen tally of the browser campaign: builds in flight with an ETA,
conformance verdicts, and runtime perf vs Playwright's official images.

    scripts/tally.py            # everything
    scripts/tally.py builds     # one section: builds | conformance | perf
    scripts/tally.py --ab 20    # read more chs-perf-ab runs (default 12)

Reads GitHub through `gh` and caches every completed run's job list and perf
artifacts under $XDG_CACHE_HOME/ci-prebuilds-tally (a completed run never
changes), so a repeat call costs one `gh run list` per workflow.

Ratios are OURS / OFFICIAL everywhere (1.19 = we take 19 % longer); the probe
report and chs-perf-ab print the inverse, official/ours.

PERF has three sources. "shipped" rows are main's test-and-publish runs: the
`main sha` is the commit that run built the consumer image from, the browsers
inside are whatever Dockerfile.alpine pins (chs-1234/ff-1538/wk-2336), so
consecutive rows are re-draws of the SAME image on whichever runner GitHub
handed out. "candidates" rows are perf-gate jobs (candidate, promoted and
official probed on one runner, `runs` shots each): the candidate is shown
against official, with the promoted build's own ratio on that same runner
underneath as the reference. chs-perf-ab rows are the older two-cell A/B.
"""
import argparse
import datetime as dt
import json
import math
import os
import pathlib
import re
import statistics
import subprocess
import sys

REPO = "jclaveau/ci-prebuilds"
CACHE = pathlib.Path(os.environ.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache")) / "ci-prebuilds-tally"

BUILD_WF = "playwright-alpine-browsers.yml"
PUBLISH_WF = "test-and-publish.yml"
AB_WF = "chs-perf-ab.yml"
GATE_WF = "perf-gate.yml"
BROWSERS = ("chromium", "firefox", "webkit")
CONFORMANCE_WF = "tests-conformance.yml"

# The probe's rows, by what they exercise. Controls are pure compute that a
# build cannot move (int_math is V8 JIT, libm_fmod is the shipped fmod shim);
# they say whether two cells sat on the same silicon and are left out of the
# geomean. locator_click is frame-cadence bound and pins to a whole number of
# frames on any healthy build, so it is a control too.
GROUPS = {
    "startup": ["launch", "context_page"],
    "nav": ["goto_cold", "goto_warm"],
    "render": ["layout", "dom_churn", "screenshot"],
    "js": ["eval_rtt", "js_alloc"],
    "input": ["click_force"],
    "control": ["int_math", "libm_fmod", "locator_click"],
}
CONTROLS = set(GROUPS["control"])

CHS_JOB = "build-chromium-headless-shell-from-source"
# Fallback round profile (seconds) when no completed chain is cached yet:
# the 2026-09 shape is 7 full 5 h rounds, then ~20 min link-only rounds.
FALLBACK_PROFILE = {"setup": 25 * 60, **{f"r{i}": 5.2 * 3600 for i in range(1, 8)},
                    **{f"r{i}": 20 * 60 for i in range(8, 13)}, "finalize": 25 * 60}
CONFORMANCE_TAIL = 12 * 60
# A build chain that dies between two tallies is otherwise invisible: the
# BUILDS table listed runs still in flight and nothing else, so three
# consecutive firefox failures in one night each left no trace. Chromium
# chains are long enough to be caught live; a 3h firefox build is not.
RECENT_FAILURE_WINDOW = dt.timedelta(hours=24)
DEAD_CONCLUSIONS = ("failure", "timed_out")


def gh(*args, json_out=True):
    out = subprocess.run(["gh", *args], capture_output=True, text=True, env={**os.environ, "GH_REPO": REPO})
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        return None
    return json.loads(out.stdout) if json_out else out.stdout


def runs(workflow, limit=30, extra=()):
    fields = "databaseId,status,conclusion,headBranch,headSha,createdAt,updatedAt,event,displayTitle"
    return gh("run", "list", "--workflow", workflow, "-L", str(limit), "--json", fields, *extra) or []


def jobs(run_id, completed):
    """The run's jobs, paginated (a chromium chain has > 100), cached once completed."""
    path = CACHE / "jobs" / f"{run_id}.json"
    if completed and path.exists():
        return json.loads(path.read_text())
    data = gh("api", "--paginate", f"repos/{REPO}/actions/runs/{run_id}/jobs", "-q", ".jobs[]|{name,status,conclusion,started_at,completed_at}", json_out=False)
    if data is None:
        return []
    out = [json.loads(line) for line in data.splitlines() if line.strip()]
    if completed:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(out))
    return out


def artifact(run_id, name):
    """Directory of the run's perf JSON files, downloaded once; None when absent."""
    path = CACHE / "artifacts" / str(run_id) / name
    if path.exists():
        return path if any(path.rglob("*.json")) else None
    path.mkdir(parents=True, exist_ok=True)
    if gh("run", "download", str(run_id), "-n", name, "-D", str(path), json_out=False) is None:
        return None
    return path if any(path.rglob("*.json")) else None


def artifact_names(run_id):
    """Names of the run's artifacts, cached (only asked for completed runs)."""
    path = CACHE / "artifact-names" / f"{run_id}.json"
    if path.exists():
        return json.loads(path.read_text())
    data = gh("api", "--paginate", f"repos/{REPO}/actions/runs/{run_id}/artifacts", "-q", ".artifacts[].name", json_out=False)
    names = data.split() if data else []
    if data is not None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(names))
    return names


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def hm(seconds):
    seconds = int(seconds)
    return f"{seconds // 3600}h{(seconds % 3600) // 60:02d}"


def geomean(values):
    values = [v for v in values if v and v > 0]
    return math.exp(sum(map(math.log, values)) / len(values)) if values else None


def fmt(r):
    return "  —  " if r is None else f"{r:5.2f}"


# ----------------------------------------------------------------- builds

def chs_stage(job_name):
    """setup | r<N> | finalize for a from-source chromium job name, else None."""
    if not job_name.startswith(CHS_JOB):
        return None
    tail = job_name[len(CHS_JOB):]
    if tail == "":
        return "finalize"
    if tail == "-setup":
        return "setup"
    m = re.fullmatch(r"-r(\d+)", tail)
    return f"r{m.group(1)}" if m else None


def round_profile(build_runs):
    """Per-stage durations from the newest completed chain that ran every stage."""
    for run in build_runs:
        if run["status"] != "completed":
            continue
        prof = {}
        for j in jobs(run["databaseId"], True):
            stage = chs_stage(j["name"])
            if stage and j["conclusion"] == "success" and j["started_at"] and j["completed_at"]:
                prof[stage] = (ts(j["completed_at"]) - ts(j["started_at"])).total_seconds()
        if set(FALLBACK_PROFILE) <= set(prof):
            return prof, run["headSha"][:7]
    return FALLBACK_PROFILE, "fallback"


def stage_order():
    return ["setup"] + [f"r{i}" for i in range(1, 13)] + ["finalize"]


def print_aligned(rows, indent="  "):
    """Left-aligned columns sized to the widest cell; the first row is the header."""
    ncol = max(len(r) for r in rows)
    rows = [list(map(str, r)) + [""] * (ncol - len(r)) for r in rows]
    width = [max(len(r[i]) for r in rows) for i in range(ncol)]
    for r in rows:
        print(indent + "  ".join(c.ljust(w) for c, w in zip(r, width)).rstrip())


def recent_failures(build_runs, now):
    """Build chains that died recently enough to still be the thing to look at."""
    return [r for r in build_runs
            if r["conclusion"] in DEAD_CONCLUSIONS
            and now - ts(r["updatedAt"]) < RECENT_FAILURE_WINDOW]


def section_builds(now):
    build_runs = runs(BUILD_WF, 60)
    live = [r for r in build_runs if r["status"] != "completed"]
    profile, profile_sha = round_profile(build_runs)
    print(f"BUILDS  ({now:%m-%d %H:%MZ}; round profile from {profile_sha})")
    rows = [("workflow", "branch", "sha", "run", "stage", "in", "done", "ETA", "")]
    for run in live:
        jl = jobs(run["databaseId"], False)
        running = [j for j in jl if j["status"] == "in_progress"]
        failed = [j["name"] for j in jl if j["conclusion"] == "failure"]
        # A firefox-only dispatch still carries every chromium job, skipped.
        # Counting those as a chain reported "chs between jobs 0/14" for a run
        # with no chromium in it at all.
        stages = {chs_stage(j["name"]): j for j in jl
                  if chs_stage(j["name"]) and j["conclusion"] != "skipped"}
        row = [BUILD_WF.removesuffix(".yml"), run["headBranch"], run["headSha"][:7], run["databaseId"]]
        if stages:
            done = [s for s in stage_order() if stages.get(s, {}).get("conclusion") == "success"]
            cur = [s for s in stage_order() if stages.get(s, {}).get("status") == "in_progress"]
            if cur:
                stage = cur[0]
                started = ts(stages[stage]["started_at"])
                remaining = max(0.0, profile.get(stage, 0) - (now - started).total_seconds())
                later = stage_order()[stage_order().index(stage) + 1:]
                remaining += sum(profile.get(s, 0) for s in later) + CONFORMANCE_TAIL
                eta = now + dt.timedelta(seconds=remaining)
                row += [f"chs {stage}", hm((now - started).total_seconds()), f"{len(done)}/14",
                        f"{eta:%m-%d %H:%MZ} (+{hm(remaining)})"]
            elif done and "finalize" in done:
                row += ["chs conformance", "", f"{len(done)}/14"]
            else:
                row += ["chs between jobs", "", f"{len(done)}/14"]
        else:
            # Build jobs first: a firefox dispatch also runs the chromium
            # conformance shards, and those are not what the row is about.
            running.sort(key=lambda j: not j["name"].startswith("build-"))
            row += [", ".join(j["name"] for j in running[:2]) or "queued"]
        if failed:
            row += [""] * (8 - len(row)) + [f"FAILED: {', '.join(failed[:3])}"]
        rows.append(row)
    others = [(wf, r) for wf in (AB_WF, PUBLISH_WF, "promote-chromium-from-source.yml")
              for r in runs(wf, 5) if r["status"] != "completed"]
    for wf, r in others:
        rows.append((wf.removesuffix(".yml"), r["headBranch"], r["headSha"][:7], r["databaseId"], r["status"]))
    for run in recent_failures(build_runs, now):
        failed = [j["name"] for j in jobs(run["databaseId"], True) if j["conclusion"] == "failure"]
        age = hm((now - ts(run["updatedAt"])).total_seconds())
        rows.append((BUILD_WF.removesuffix(".yml"), run["headBranch"], run["headSha"][:7],
                     run["databaseId"], run["conclusion"], f"{age} ago", "", "",
                     f"FAILED: {', '.join(failed[:3]) or 'no failed job'}"))
    if len(rows) > 1:
        print_aligned(rows)
    else:
        print("  none in flight")
    focus = live[0] if live else next((r for r in build_runs if r["status"] == "completed"), None)
    if focus:
        print(f"  Run: https://github.com/{REPO}/actions/runs/{focus['databaseId']}")
    return build_runs


def section_prs():
    # open perf candidates only; renovate and feature PRs are not the campaign
    prs = [p for p in gh("pr", "list", "--json", "number,title,headRefName,isDraft") or [] if p["headRefName"].startswith("perf/")]
    if not prs:
        return
    print("PRS  (open perf candidates)")
    print_aligned([("PR", "branch", "title")] + [
        (f"#{pr['number']}", pr["headRefName"] + (" (draft)" if pr["isDraft"] else ""), pr["title"][:70])
        for pr in prs])


# ------------------------------------------------------------ conformance

def section_conformance(build_runs, depth):
    """Newest verdict per conformance suite. Suites gated on a rare build (webkit
    runs only when webkit was rebuilt) live in old runs, so verdicts persist in
    the cache and each call only scans runs newer than the newest it has seen;
    `--depth 300` once fills the cache from before that."""
    print("CONFORMANCE  (newest verdict per suite)")
    path = CACHE / "conformance.json"
    seen = json.loads(path.read_text()) if path.exists() else {}
    newest = max((v["created"] for v in seen.values()), default="")
    pool = [r for r in build_runs if r["status"] == "completed"]
    if depth > len(build_runs):
        pool = [r for r in runs(BUILD_WF, depth) if r["status"] == "completed"]
    pool += [r for r in runs(CONFORMANCE_WF, 10) if r["status"] == "completed"]
    pool.sort(key=lambda r: r["createdAt"], reverse=True)
    for run in pool:
        if run["createdAt"] <= newest and depth <= 60:
            break
        for j in jobs(run["databaseId"], True):
            name = j["name"]
            if not name.startswith("conformance") or "shard (" in name or j["conclusion"] in (None, "skipped", "cancelled"):
                continue
            fam = name.replace(" / summary", "")
            if fam not in seen or seen[fam]["created"] < run["createdAt"]:
                seen[fam] = {"verdict": j["conclusion"], "created": run["createdAt"], "run": run["databaseId"],
                             "branch": run["headBranch"], "sha": run["headSha"][:7]}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(seen))
    print_aligned([("", "suite", "branch", "sha", "run", "date")] + [
        ("OK" if v["verdict"] == "success" else "RED", fam, v["branch"], v["sha"], v["run"], v["created"][5:10])
        for fam, v in sorted(seen.items())])


# ------------------------------------------------------------------ perf

def load_cells(directory):
    """{(browser, target): {'cpu', 'libc', 'shots', 'metrics': {metric: median_ms}}} medianed across repeats."""
    collected, meta = {}, {}
    for path in sorted(pathlib.Path(directory).rglob("*.json")):
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue
        if not {"metrics", "browser", "target"} <= set(doc):
            continue
        key = (doc["browser"], doc["target"])
        meta.setdefault(key, {"cpu": doc.get("runner", {}).get("cpu", "?"), "libc": doc.get("libc", "?"), "shots": 0})
        meta[key]["shots"] += 1
        for metric, value in doc["metrics"].items():
            collected.setdefault(key, {}).setdefault(metric, []).append(value["median_ms"])
            meta[key].setdefault("samples", {}).setdefault(metric, []).extend(value.get("samples", []))
    return {k: {**meta[k], "shot_medians": per, "metrics": {m: statistics.median(v) for m, v in per.items()}}
            for k, per in collected.items()}


def ab_labels(run_id):
    """(label_a, label_b) of a chs-perf-ab run, read once from its job log."""
    path = CACHE / "ab-labels" / f"{run_id}.json"
    if path.exists():
        return tuple(json.loads(path.read_text()))
    ids = gh("api", f"repos/{REPO}/actions/runs/{run_id}/jobs", "-q", ".jobs[0].id", json_out=False)
    log = gh("api", f"repos/{REPO}/actions/jobs/{(ids or '').strip()}/logs", json_out=False) or ""
    found = dict(re.findall(r"LABEL_([AB]): (\S+)", log))
    labels = (found.get("A"), found.get("B"))
    if all(labels):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(labels))
    return labels


def gate_tags(run_id):
    """(candidate_tag, promoted_tag) of a perf-gate job, read once from its log."""
    path = CACHE / "gate-tags" / f"{run_id}.json"
    if path.exists():
        return tuple(json.loads(path.read_text()))
    found = {}
    for jid in (gh("api", f"repos/{REPO}/actions/runs/{run_id}/jobs", "-q", ".jobs[]|select(.name|test(\"perf-gate\"))|.id", json_out=False) or "").split():
        log = gh("api", f"repos/{REPO}/actions/jobs/{jid}/logs", json_out=False) or ""
        found.update(re.findall(r"stage (candidate|promoted) \(ghcr\.io/[^:]+:(\S+)\)", log))
    tags = (found.get("candidate"), found.get("promoted"))
    if tags[0]:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(tags))
    return tags


def significant(ours, base, metric):
    """Shots are the independent unit (iterations inside one share process state):
    with >= 2 shots a side, the delta counts only when the two sets of shot medians
    do not overlap (Mann-Whitney U=0; p=1/20 one-sided at 3 vs 3). A single shot
    falls back to chs-perf-ab's rule: a delta inside either side's own raw sample
    spread measures nothing. Pooling raw samples across shots would only widen
    that spread, so more shots would flag MORE noise."""
    ma, mb = ours.get("shot_medians", {}).get(metric, []), base.get("shot_medians", {}).get(metric, [])
    if len(ma) >= 2 and len(mb) >= 2:
        return min(ma) > max(mb) or max(ma) < min(mb)
    sa, sb = ours.get("samples", {}).get(metric, []), base.get("samples", {}).get(metric, [])
    if not sa or not sb:
        return True
    spread = max(max(sa) - min(sa), max(sb) - min(sb))
    return abs(ours["metrics"][metric] - base["metrics"][metric]) >= spread


def ratio_row(ours, base):
    """{metric: ours/base} plus the group geomeans and the overall one (controls excluded).

    Ratios are raw medians; a group whose rows are all inside their sample
    spread is flagged '~' (the delta is noise-sized), never clamped. The
    overall geomean is over every non-control row, raw — comparable with the
    figures in the memories (baseline 1.42, PGO+ThinLTO 1.12, …)."""
    per, ns = {}, set()
    for m in ours["metrics"]:
        if not base["metrics"].get(m):
            continue
        per[m] = ours["metrics"][m] / base["metrics"][m]
        if not significant(ours, base, m):
            ns.add(m)
    groups = {g: geomean([per[m] for m in ms if m in per]) for g, ms in GROUPS.items()}
    marks = {g: all(m in ns for m in ms if m in per) for g, ms in GROUPS.items()}
    return per, {"values": groups, "ns": marks}, geomean([v for m, v in per.items() if m not in CONTROLS])


def cpu_short(cpu):
    """'AMD EPYC 7763 64-Core Processor' -> 'EPYC 7763'; Intel -> its model number."""
    m = re.search(r"EPYC \S+", cpu) or re.search(r"\b\d{4}[A-Z]{0,2}\b", cpu)
    return (m.group(0) if m else cpu)[:14]


def print_table(title, head, rows):
    """rows: [(label, cpu, shots, groups, overall)]; one line each, group geomeans in GROUPS order.

    head names the label column. shots is the probe invocations behind the row
    (blank on aggregate rows). groups is {'values': {group: geo}, 'ns': {group:
    bool}, 'above': {group: (k, n)}}; '~' marks a group whose every row sat
    inside its own shot spread, 'k/n' the draws of an aggregate reading > 1.00."""
    print(f"  {title}")
    print(f"    {head[:40]:<40} {'cpu':<10} {'n':>2} " + " ".join(f"{g:>11}" for g in GROUPS) + "     geo")
    for label, cpu, shots, groups, overall in rows:
        cells = []
        for g in GROUPS:
            k, n = groups.get("above", {}).get(g, (0, 0))
            cells.append(fmt(groups["values"].get(g)) + ("~" if groups["ns"].get(g) else " ") + (f" {k}/{n}" if n else "    "))
        print(f"    {label[:40]:<40} {cpu[:10]:<10} {str(shots or ''):>2} " + " ".join(c.rjust(11) for c in cells) + f"   {fmt(overall)}")


def aggregate(rows, weights=None):
    """Geomean of several rows' group values; a group is '~' when every row was.

    weights, when given, weight each row's log (a fleet-share weighting); they
    are renormalised over the rows that carry the group."""
    weights = weights or [1.0] * len(rows)
    values = {}
    for g in GROUPS:
        pairs = [(r["values"].get(g), w) for r, w in zip(rows, weights) if r["values"].get(g)]
        total = sum(w for _, w in pairs)
        values[g] = math.exp(sum(w * math.log(v) for v, w in pairs) / total) if total else None
    ns = {g: all(r["ns"].get(g) for r in rows) for g in GROUPS}
    # draws are independent, so k of N reading > 1.00 is the sign test the
    # single rows cannot run: 6/6 or 0/6 is p = 1/32 two-sided
    above = {}
    for g in GROUPS:
        if any("above" in r for r in rows):  # aggregating aggregates: carry the draw counts through
            above[g] = (sum(r["above"][g][0] for r in rows if "above" in r), sum(r["above"][g][1] for r in rows if "above" in r))
        else:
            above[g] = (sum(1 for r in rows if (r["values"].get(g) or 0) > 1), sum(1 for r in rows if r["values"].get(g)))
    return {"values": values, "ns": ns, "above": above}


def weighted_geomean(values, weights):
    pairs = [(v, w) for v, w in zip(values, weights) if v and v > 0]
    total = sum(w for _, w in pairs)
    return math.exp(sum(w * math.log(v) for v, w in pairs) / total) if total else None


def fleet_mix():
    """{cpu_short: share} of runner models over every probe job in the cache.

    One job = one draw from the fleet: a test-and-publish perf-<browser> job, a
    perf-gate job, a chs-perf-ab job. Every JSON in a job's artifact sat on the
    same runner, so the first doc per (run, artifact, browser) is the draw."""
    seen = {}
    for path in (CACHE / "artifacts").rglob("*.json"):
        key = path.relative_to(CACHE / "artifacts").parts[:2]
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue
        if "browser" in doc and "runner" in doc:
            seen.setdefault((*key, doc["browser"]), cpu_short(doc["runner"].get("cpu", "?")))
    counts = {}
    for cpu in seen.values():
        counts[cpu] = counts.get(cpu, 0) + 1
    total = sum(counts.values())
    return {cpu: n / total for cpu, n in sorted(counts.items(), key=lambda kv: -kv[1])}, total


def shipped_rows():
    """{browser: [(run, cell, groups, overall)]} from main's test-and-publish runs, newest first."""
    per_browser = {}
    for run in [r for r in runs(PUBLISH_WF, 30) if r["status"] == "completed" and r["headBranch"] == "main"]:
        d = artifact(run["databaseId"], "runtime-perf")
        if not d:
            continue
        cells = load_cells(d)
        for (browser, target), cell in cells.items():
            if target != "alpine" or (browser, "official") not in cells:
                continue
            _, groups, overall = ratio_row(cell, cells[(browser, "official")])
            per_browser.setdefault(browser, []).append((run, cell, groups, overall))
        if all(len(v) >= 6 for v in per_browser.values()) and len(per_browser) >= 3:
            break
    return per_browser


def gate_rows(build_runs, gate_limit):
    """{browser: [(run, tags, cells)]} from every completed perf-gate job: dispatches of
    perf-gate.yml and the perf-gate-<browser> jobs the build workflow calls."""
    out = {}
    pool = [(r, True) for r in runs(GATE_WF, gate_limit) if r["status"] == "completed"]
    pool += [(r, False) for r in build_runs if r["status"] == "completed"
             and any(j["name"].startswith("perf-gate-") and j["conclusion"] == "success" for j in jobs(r["databaseId"], True))]
    for run, dispatched in sorted(pool, key=lambda p: p[0]["createdAt"], reverse=True):
        for name in [n for n in artifact_names(run["databaseId"]) if n.startswith("perf-gate-")]:
            d = artifact(run["databaseId"], name)
            if not d:
                continue
            cells = {t: c for (b, t), c in load_cells(d).items() if b == name.removeprefix("perf-gate-")}
            if "candidate" not in cells or "official" not in cells:
                continue
            # a dispatched gate names its images only in the log; a build-workflow
            # gate's candidate is the build itself (branch@sha)
            tags = gate_tags(run["databaseId"]) if dispatched else (None, None)
            out.setdefault(name.removeprefix("perf-gate-"), []).append((run, tags, cells))
    return out


def ab_rows(ab_limit):
    table = []
    for run in [r for r in runs(AB_WF, ab_limit) if r["status"] == "completed" and r["conclusion"] == "success"]:
        d = artifact(run["databaseId"], "chs-perf-ab")
        if not d:
            continue
        cells = {t: c for (b, t), c in load_cells(d).items() if b == "chromium"}
        if len(cells) != 2:
            continue
        la, lb = ab_labels(run["databaseId"])
        if la not in cells or lb not in cells:
            la, lb = sorted(cells)
        if la == "official":
            ours, base, label = cells[lb], cells[la], f"{lb} vs official"
        elif lb == "official":
            ours, base, label = cells[la], cells[lb], f"{la} vs official"
        else:
            ours, base, label = cells[lb], cells[la], f"{lb} / {la}"
        _, groups, overall = ratio_row(ours, base)
        table.append((f"{run['createdAt'][5:10]} {label}", cpu_short(ours["cpu"]), min(ours["shots"], base["shots"]), groups, overall))
    return table


def section_perf(ab_limit, gate_limit):
    print("PERF  ours/official. '~' = every row of the group inside its shot spread (noise); k/n = draws of an aggregate reading > 1.00; n = probe shots behind the row; geo = non-control rows, raw")
    shipped = shipped_rows()
    gates = gate_rows(runs(BUILD_WF, 60), gate_limit)
    ab = ab_rows(ab_limit)
    mix, jobs_seen = fleet_mix()
    for browser in BROWSERS:
        rows = shipped.get(browser, [])
        if not rows:
            continue
        table = []
        for run, cell, groups, overall in rows[:4]:
            table.append((f"{run['headSha'][:7]} {run['createdAt'][5:10]} {run['databaseId']}", cpu_short(cell["cpu"]), cell["shots"], groups, overall))
        by_cpu = {}
        for run, cell, groups, overall in rows:
            by_cpu.setdefault(cpu_short(cell["cpu"]), []).append((groups, overall))
        for cpu, lst in sorted(by_cpu.items()):
            table.append((f"  per-cpu geo (n={len(lst)})", cpu, "", aggregate([x[0] for x in lst]), geomean([x[1] for x in lst])))
        table.append((f"  global geo (n={len(rows)} draws, as drawn)", "all", "", aggregate([x[2] for x in rows]), geomean([x[3] for x in rows])))
        # the same per-cpu geos, weighted by how often the fleet hands out each
        # model rather than by how many of these few draws happened to land on it
        cpus = sorted(by_cpu)
        weights = [mix.get(c, 0.0) for c in cpus]
        if sum(weights):
            table.append(("  fleet geo (per-cpu geo x fleet share)", "all", "",
                          aggregate([aggregate([x[0] for x in by_cpu[c]]) for c in cpus], weights),
                          weighted_geomean([geomean([x[1] for x in by_cpu[c]]) for c in cpus], weights)))
        print_table(f"shipped {browser} (main test-and-publish; same pinned browsers re-drawn per run, alpine vs official in one job)",
                    "main sha date  run", table)
    # candidates: perf-gate jobs, candidate vs official with the promoted build's
    # ratio on the same runner as the reference line
    for browser in BROWSERS:
        table = []
        for run, (cand_tag, prom_tag), cells in gates.get(browser, []):
            cand = cand_tag or f"{run['headBranch']}@{run['headSha'][:7]}"
            _, groups, overall = ratio_row(cells["candidate"], cells["official"])
            table.append((f"{run['createdAt'][5:10]} {cand} vs official", cpu_short(cells["candidate"]["cpu"]), cells["candidate"]["shots"], groups, overall))
            if "promoted" in cells:
                _, groups, overall = ratio_row(cells["promoted"], cells["official"])
                table.append((f"      {prom_tag or f'{browser[:2]}-latest'} vs official (same job)", "", cells["promoted"]["shots"], groups, overall))
        if table:
            print_table(f"{browser} candidates (perf-gate; candidate vs official, then what the promoted build does on that runner)", "date  candidate", table)
    if ab:
        print_table("chromium A/B (chs-perf-ab; 'B / A' = candidate over its baseline, both ours; prefer perf-gate for vs-official)", "date  pair", ab)
    if mix:
        print(f"  GHA runner mix over {jobs_seen} cached probe jobs: " + ", ".join(f"{cpu} {share:.0%}" for cpu, share in mix.items()))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("section", nargs="?", choices=["builds", "conformance", "perf"])
    ap.add_argument("--ab", type=int, default=12, help="chs-perf-ab runs to read")
    ap.add_argument("--gate", type=int, default=12, help="perf-gate dispatch runs to read (build-workflow gates are found via their jobs)")
    ap.add_argument("--depth", type=int, default=60, help="build runs to scan for conformance verdicts (300 once to seed the cache)")
    args = ap.parse_args()
    now = dt.datetime.now(dt.timezone.utc)
    build_runs = None
    if args.section in (None, "builds"):
        build_runs = section_builds(now)
        section_prs()
    if args.section in (None, "conformance"):
        section_conformance(build_runs if build_runs is not None else runs(BUILD_WF, 60), args.depth)
    if args.section in (None, "perf"):
        section_perf(args.ab, args.gate)


if __name__ == "__main__":
    main()
