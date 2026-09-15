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
ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = pathlib.Path(os.environ.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache")) / "ci-prebuilds-tally"

BUILD_WF = "playwright-alpine-browsers.yml"
PUBLISH_WF = "test-and-publish.yml"
AB_WF = "chs-perf-ab.yml"
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


def gh(*args, json_out=True):
    out = subprocess.run(["gh", *args], capture_output=True, text=True, cwd=ROOT)
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


def section_builds(now):
    build_runs = runs(BUILD_WF, 60)
    live = [r for r in build_runs if r["status"] != "completed"]
    profile, profile_sha = round_profile(build_runs)
    print(f"BUILDS  ({now:%m-%d %H:%MZ}; round profile from {profile_sha})")
    if not live:
        print("  none in flight")
    for run in live:
        jl = jobs(run["databaseId"], False)
        running = [j for j in jl if j["status"] == "in_progress"]
        failed = [j["name"] for j in jl if j["conclusion"] == "failure"]
        stages = {chs_stage(j["name"]): j for j in jl if chs_stage(j["name"])}
        line = f"  {run['headBranch']} {run['headSha'][:7]} {run['databaseId']}:"
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
                line += f" chs {stage} ({hm((now - started).total_seconds())} in), {len(done)}/14 stages, ETA {eta:%m-%d %H:%MZ} (+{hm(remaining)})"
            elif done and "finalize" in done:
                line += " chs built, conformance running"
            else:
                line += f" chs {len(done)}/14 stages, between jobs"
        else:
            names = ", ".join(j["name"] for j in running[:3]) or "queued"
            line += f" {names}"
        if failed:
            line += f"  FAILED: {', '.join(failed[:3])}"
        print(line)
    others = [(wf, r) for wf in (AB_WF, PUBLISH_WF, "promote-chromium-from-source.yml")
              for r in runs(wf, 5) if r["status"] != "completed"]
    for wf, r in others:
        print(f"  {wf.removesuffix('.yml')} {r['databaseId']} {r['headBranch']}: {r['status']}")
    # open perf candidates only; renovate and feature PRs are not the campaign
    prs = [p for p in gh("pr", "list", "--json", "number,title,headRefName,isDraft") or [] if p["headRefName"].startswith("perf/")]
    for pr in prs:
        print(f"  PR #{pr['number']} {pr['headRefName']}{' (draft)' if pr['isDraft'] else ''}: {pr['title'][:70]}")
    focus = live[0] if live else next((r for r in build_runs if r["status"] == "completed"), None)
    if focus:
        print(f"  Run: https://github.com/{REPO}/actions/runs/{focus['databaseId']}")
    return build_runs


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
    for fam, v in sorted(seen.items()):
        mark = "OK " if v["verdict"] == "success" else "RED"
        print(f"  {mark} {fam:<48} {v['branch']}@{v['sha']} {v['run']} {v['created'][5:10]}")


# ------------------------------------------------------------------ perf

def load_cells(directory):
    """{(browser, target): {'cpu', 'libc', 'metrics': {metric: median_ms}}} medianed across repeats."""
    collected, meta = {}, {}
    for path in sorted(pathlib.Path(directory).rglob("*.json")):
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue
        if not {"metrics", "browser", "target"} <= set(doc):
            continue
        key = (doc["browser"], doc["target"])
        meta.setdefault(key, {"cpu": doc.get("runner", {}).get("cpu", "?"), "libc": doc.get("libc", "?")})
        for metric, value in doc["metrics"].items():
            collected.setdefault(key, {}).setdefault(metric, []).append(value["median_ms"])
            meta[key].setdefault("samples", {}).setdefault(metric, []).extend(value.get("samples", []))
    return {k: {**meta[k], "metrics": {m: statistics.median(v) for m, v in per.items()}} for k, per in collected.items()}


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


def significant(ours, base, metric):
    """chs-perf-ab's rule: a delta inside either side's own sample spread measures nothing."""
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


def print_table(title, rows):
    """rows: [(label, cpu, groups, overall)]; one line each, group geomeans in GROUPS order.

    groups is {'values': {group: geo}, 'ns': {group: bool}}; '~' marks a group
    whose every row sat inside its own sample spread."""
    print(f"  {title}")
    print(f"    {'':<38} {'cpu':<10} " + " ".join(f"{g:>7}" for g in GROUPS) + "   geo")
    for label, cpu, groups, overall in rows:
        cells = [fmt(groups["values"].get(g)) + ("~" if groups["ns"].get(g) else " ") for g in GROUPS]
        print(f"    {label[:38]:<38} {cpu[:10]:<10} " + " ".join(c.rjust(7) for c in cells) + f" {fmt(overall)}")


def aggregate(rows):
    """Geomean of several rows' group values; a group is '~' when every row was."""
    values = {g: geomean([r["values"].get(g) for r in rows]) for g in GROUPS}
    ns = {g: all(r["ns"].get(g) for r in rows) for g in GROUPS}
    return {"values": values, "ns": ns}


def section_perf(ab_limit):
    print("PERF  ours/official. '~' = every row of the group inside its sample spread (noise); geo = non-control rows, raw")
    # shipped: main test-and-publish runs, alpine cell vs official cell, per browser
    shipped = [r for r in runs(PUBLISH_WF, 30) if r["status"] == "completed" and r["headBranch"] == "main"]
    per_browser = {}
    for run in shipped:
        d = artifact(run["databaseId"], "runtime-perf")
        if not d:
            continue
        cells = load_cells(d)
        for (browser, target), cell in cells.items():
            if target != "alpine" or (browser, "official") not in cells:
                continue
            _, groups, overall = ratio_row(cell, cells[(browser, "official")])
            per_browser.setdefault(browser, []).append((run, cell["cpu"], groups, overall))
        if all(len(v) >= 6 for v in per_browser.values()) and len(per_browser) >= 3:
            break
    for browser in ("chromium", "firefox", "webkit"):
        rows = per_browser.get(browser, [])
        if not rows:
            continue
        table = []
        for run, cpu, groups, overall in rows[:4]:
            table.append((f"{run['headSha'][:7]} {run['createdAt'][5:10]} {run['databaseId']}", cpu_short(cpu), groups, overall))
        by_cpu = {}
        for run, cpu, groups, overall in rows:
            by_cpu.setdefault(cpu_short(cpu), []).append((groups, overall))
        for cpu, lst in sorted(by_cpu.items()):
            table.append((f"  per-cpu geo (n={len(lst)})", cpu, aggregate([x[0] for x in lst]), geomean([x[1] for x in lst])))
        table.append((f"  global geo (n={len(rows)})", "all", aggregate([x[2] for x in rows]), geomean([x[3] for x in rows])))
        print_table(f"shipped {browser} (main test-and-publish, alpine vs official in the same run)", table)
    # candidates: chs-perf-ab runs, B vs A; when one side is official, ours/official
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
        table.append((f"{run['createdAt'][5:10]} {label}", cpu_short(ours["cpu"]), groups, overall))
    if table:
        print_table("chromium candidates (chs-perf-ab; 'B / A' = candidate over its baseline, both ours)", table)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("section", nargs="?", choices=["builds", "conformance", "perf"])
    ap.add_argument("--ab", type=int, default=12, help="chs-perf-ab runs to read")
    ap.add_argument("--depth", type=int, default=60, help="build runs to scan for conformance verdicts (300 once to seed the cache)")
    args = ap.parse_args()
    now = dt.datetime.now(dt.timezone.utc)
    build_runs = None
    if args.section in (None, "builds"):
        build_runs = section_builds(now)
    if args.section in (None, "conformance"):
        section_conformance(build_runs if build_runs is not None else runs(BUILD_WF, 60), args.depth)
    if args.section in (None, "perf"):
        section_perf(args.ab)


if __name__ == "__main__":
    main()
