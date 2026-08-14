#!/usr/bin/env python3
"""Snapshot the CI and registry facts that GitHub throws away.

Writes append-only JSONL under metrics/, partitioned by month so a weekly
append only rewrites the current month's blob instead of the whole history:

    metrics/runs/YYYY-MM.jsonl       one row per workflow run attempt
    metrics/jobs/YYYY-MM.jsonl       one row per job, WITH its per-step timings
    metrics/images/YYYY-MM.jsonl     one row per (package, digest) with the
                                     compressed layer bytes
    metrics/artifacts/YYYY-MM.jsonl  one row per artifact, with expires_at

The per-step timings are the point of `jobs`. Both benchmark headline numbers
are derived from them and from nothing else that survives:

    time-to-tests = job start        -> start of the "Run Playwright tests" step
    test time     = that step's own duration

Retention this is racing (measured 2026-08-14, repo created 2025-10-17):

  - run + job metadata, including steps: complete back to day one, 2110 runs,
    no expiry. It is the only complete source, which is why the backfill takes
    all of it rather than a recent window.
  - run LOGS: 90 days. 2026-05-28 still served, 2025-10-21 already 410 Gone.
    Anything log-derived (ninja counters, per-test tallies) is recoverable only
    inside that window and rolls off daily.
  - artifacts: 14/30/90 days per upload, whatever the workflow asked for.
  - GHCR: the versions API keeps created_at + tags but never a size. Sizes live
    only in the manifests, so a size series has to be sampled — once a version
    is deleted nobody can reconstruct what it weighed.

`billable` is deliberately not stored: on a public repo every duration_ms in it
is 0, and the blob carries one entry per job. Runner-minutes, summed from the
job rows, is the real cost unit.

Usage:
    collect-metrics.py runs [--since YYYY-MM-DD] [--limit N] [--refresh]
    collect-metrics.py images [--packages a,b,c]
    collect-metrics.py artifacts
    collect-metrics.py all
"""
import argparse
import concurrent.futures
import fcntl
import json
import os
import pathlib
import subprocess
import sys
import time

REPO = os.environ.get("METRICS_REPO", "jclaveau/ci-prebuilds")
OWNER = REPO.split("/")[0]
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "metrics"

# Consumer images we publish, plus the browser-artifact package whose tags
# (chs-fs-*, ff-*, wk-*) are the interesting axis rather than its name.
DEFAULT_PACKAGES = [
    "alpine-dood-playwright",
    "alpine-dind-playwright",
    "ubuntu-dood-playwright",
    "ubuntu-dind-playwright",
    "alpine-dood",
    "alpine-dind",
    "ubuntu-dood",
    "ubuntu-dind",
    "alpine-gha-tools",
    "ubuntu-gha-tools",
    "playwright-alpine-browsers",
]


def gh(path, paginate=False, retries=3):
    """One REST call. Sleeps through a spent rate limit rather than truncating
    the backfill, since a partial history is indistinguishable from a real gap."""
    cmd = ["gh", "api"]
    if paginate:
        cmd += ["--paginate", "--slurp"]
    cmd.append(path)
    for attempt in range(retries):
        out = subprocess.run(cmd, capture_output=True, text=True)
        if out.returncode == 0:
            try:
                return json.loads(out.stdout)
            except json.JSONDecodeError:
                return None
        err = out.stderr.lower()
        if "rate limit" in err or "secondary rate" in err:
            wait = rate_limit_wait()
            print(f"  rate limited, sleeping {wait}s", file=sys.stderr)
            time.sleep(wait)
            continue
        if attempt == retries - 1:
            return None
        time.sleep(2 * (attempt + 1))
    return None


def rate_limit_wait():
    out = subprocess.run(
        ["gh", "api", "rate_limit", "--jq", ".resources.core.reset"],
        capture_output=True, text=True,
    )
    try:
        return max(10, int(out.stdout.strip()) - int(time.time()) + 5)
    except ValueError:
        return 60


class Partitioned:
    """Append-only JSONL split into metrics/<kind>/YYYY-MM.jsonl.

    Monthly files keep the git blob churn proportional to what actually
    changed: a weekly append touches one file, and every earlier month stays
    byte-identical forever.
    """

    def __init__(self, kind, key, month):
        self.dir = OUT / kind
        self.key, self.month = key, month
        self.seen = set()
        self.unsettled = set()  # stored with no conclusion yet — still worth re-fetching
        self.buffers = {}
        if self.dir.exists():
            for path in self.dir.glob("*.jsonl"):
                with path.open() as fh:
                    for line in fh:
                        try:
                            row = json.loads(line)
                            row_key = key(row)
                        except (json.JSONDecodeError, KeyError, TypeError):
                            continue
                        self.seen.add(row_key)
                        if row.get("conclusion"):
                            self.unsettled.discard(row_key)
                        else:
                            self.unsettled.add(row_key)

    def has(self, row_key):
        return row_key in self.seen

    def add(self, row, supersede=False):
        """Append unless the key is already stored.

        `supersede` re-appends a key that IS stored, for the one case the store
        has to handle: a row snapshotted mid-flight. A run or job caught
        in_progress has a null conclusion and no completed_at, and would keep
        those forever otherwise. Append-only means the later row simply wins on
        read — see `latest_by_key` in metrics-report.py.
        """
        row_key = self.key(row)
        if row_key in self.seen and not supersede:
            return False
        self.seen.add(row_key)
        self.buffers.setdefault(self.month(row), []).append(row)
        return True

    def flush(self):
        self.dir.mkdir(parents=True, exist_ok=True)
        written = 0
        for month, rows in self.buffers.items():
            with (self.dir / f"{month}.jsonl").open("a") as fh:
                for row in rows:
                    fh.write(json.dumps(row, separators=(",", ":")) + "\n")
                written += len(rows)
        self.buffers.clear()
        return written


def compact_steps(steps):
    """[number, name, conclusion, started_at, completed_at] per step.

    Positional rather than keyed: steps are the bulk of the dataset and the
    field names would outweigh the values.
    """
    return [
        [s.get("number"), s.get("name"), s.get("conclusion"),
         s.get("started_at"), s.get("completed_at")]
        for s in steps or []
    ]


def collect_runs(since, limit, refresh):
    runs = Partitioned("runs", lambda r: (r["id"], r["run_attempt"]),
                       lambda r: (r["created_at"] or "")[:7])
    jobs = Partitioned("jobs", lambda r: r["id"],
                       lambda r: (r["started_at"] or r["created_at"] or "")[:7])

    page, seen_runs, new_runs, stop = 1, 0, 0, False
    while not stop:
        batch = gh(f"repos/{REPO}/actions/runs?per_page=100&page={page}")
        if not batch or not batch.get("workflow_runs"):
            break
        for run in batch["workflow_runs"]:
            seen_runs += 1
            if since and (run["created_at"] or "")[:10] < since:
                stop = True
                break
            key = (run["id"], run.get("run_attempt", 1))
            # Stored and settled: nothing about it can change again. Stored but
            # snapshotted mid-flight: re-fetch, so the long browser builds do
            # not stay `in_progress` in the record forever.
            resnapshot = key in runs.unsettled
            if runs.has(key) and not (resnapshot or refresh):
                continue
            runs.add(supersede=True, row={
                "id": run["id"],
                "run_attempt": run.get("run_attempt", 1),
                "workflow": run.get("name"),
                "workflow_id": run.get("workflow_id"),
                "path": run.get("path"),
                "event": run.get("event"),
                "branch": run.get("head_branch"),
                "sha": run.get("head_sha"),
                "status": run.get("status"),
                "conclusion": run.get("conclusion"),
                "created_at": run.get("created_at"),
                "run_started_at": run.get("run_started_at"),
                "updated_at": run.get("updated_at"),
            })
            new_runs += 1

            pages = gh(f"repos/{REPO}/actions/runs/{run['id']}/jobs?per_page=100",
                       paginate=True)
            for chunk in pages or []:
                for job in chunk.get("jobs", []):
                    if jobs.has(job["id"]) and job["id"] not in jobs.unsettled:
                        continue
                    jobs.add(supersede=True, row={
                        "id": job["id"],
                        "run_id": run["id"],
                        "run_attempt": job.get("run_attempt", 1),
                        "workflow": run.get("name"),
                        "branch": run.get("head_branch"),
                        "sha": run.get("head_sha"),
                        "event": run.get("event"),
                        "name": job.get("name"),
                        "status": job.get("status"),
                        "conclusion": job.get("conclusion"),
                        "created_at": job.get("created_at"),
                        "started_at": job.get("started_at"),
                        "completed_at": job.get("completed_at"),
                        "runner_name": job.get("runner_name"),
                        "labels": job.get("labels"),
                        "steps": compact_steps(job.get("steps")),
                    })
            if new_runs % 25 == 0:
                print(f"  {new_runs} new runs "
                      f"(at {run['created_at'][:10]}), flushing")
                runs.flush()
                jobs.flush()
            if limit and new_runs >= limit:
                stop = True
                break
        page += 1
    nr, nj = runs.flush(), jobs.flush()
    print(f"scanned {seen_runs} runs; +{nr} run rows, +{nj} job rows")


def collect_images(packages, workers=8):
    # Keyed on (package, digest): the bytes for a digest never change, so a
    # re-run prices only versions it has not seen. Tags DO move, so `tags` is
    # the tag set at snapshot time and `snapshot_at` says when that was.
    images = Partitioned("images", lambda r: (r["package"], r["digest"]),
                         lambda r: (r["created_at"] or "")[:7])
    snapshot_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    total = 0
    for pkg in packages:
        versions = gh(f"users/{OWNER}/packages/container/{pkg}/versions?per_page=100",
                      paginate=True)
        if not versions:
            print(f"  {pkg}: no versions readable", file=sys.stderr)
            continue
        flat = [v for chunk in versions for v in chunk]
        todo = []
        for v in flat:
            tags = ((v.get("metadata") or {}).get("container") or {}).get("tags") or []
            digest = v.get("name")
            # Untagged versions are the bulk (intermediate cache manifests) and
            # cannot be attributed to anything, so they are skipped.
            if not tags or images.has((pkg, digest)):
                continue
            todo.append((v, tags, digest))

        # Each price is one registry round-trip in its own subprocess, so the
        # wall time is network latency times 5000-odd versions unless they
        # overlap. Ordering does not matter: rows are keyed by digest.
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            infos = pool.map(
                lambda t: manifest_layers(f"ghcr.io/{OWNER}/{pkg}@{t[2]}"), todo)
            for (v, tags, digest), layers in zip(todo, infos):
                images.add({
                    "package": pkg,
                    "digest": digest,
                    "tags": tags,
                    "created_at": v.get("created_at"),
                    "updated_at": v.get("updated_at"),
                    "snapshot_at": snapshot_at,
                    "compressed_bytes": (sum(size for _, size in layers)
                                         if layers else None),
                    "layers": layers,
                })
        print(f"  {pkg}: {len(flat)} versions, +{len(todo)} priced", flush=True)
        images.flush()
        total += len(todo)
    print(f"+{total} image rows")


def manifest_layers(ref):
    """[[blob digest, compressed size], ...] for the linux/amd64 manifest.

    The digests are what makes an occupancy figure possible: GHCR stores a blob
    once no matter how many manifests reference it, so summing per-manifest
    totals across a package counts every shared base layer once per tag. Only
    the union of distinct digests is the real footprint.
    """
    raw = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", "--raw", ref],
        capture_output=True, text=True,
    )
    if raw.returncode != 0:
        return None
    try:
        doc = json.loads(raw.stdout)
    except json.JSONDecodeError:
        return None
    if "layers" in doc:
        blobs = list(doc["layers"])
        if doc.get("config", {}).get("digest"):
            blobs.append(doc["config"])
        return [[b["digest"], b.get("size", 0)] for b in blobs]
    for m in doc.get("manifests", []):
        platform = m.get("platform") or {}
        if platform.get("architecture") == "amd64" and platform.get("os") == "linux":
            return manifest_layers(f"{ref.split('@')[0]}@{m['digest']}")
    return None


def collect_artifacts():
    # Artifacts expire on their own per-upload schedule, so this is both an
    # inventory and a countdown: expires_at says what is about to be lost.
    arts = Partitioned("artifacts", lambda r: r["id"],
                       lambda r: (r["created_at"] or "")[:7])
    pages = gh(f"repos/{REPO}/actions/artifacts?per_page=100", paginate=True)
    for chunk in pages or []:
        for a in chunk.get("artifacts", []):
            arts.add({
                "id": a["id"],
                "run_id": (a.get("workflow_run") or {}).get("id"),
                "name": a.get("name"),
                "size_in_bytes": a.get("size_in_bytes"),
                "created_at": a.get("created_at"),
                "expires_at": a.get("expires_at"),
                "expired": a.get("expired"),
            })
    print(f"+{arts.flush()} artifact rows")


def lock(kind):
    """One collector per kind. Two concurrent appenders each load `seen` before
    the other writes, so both consider every row new and the file ends up with
    each row twice — which is exactly what happened when a shell error let a
    launch fire a second time (30248 artifact rows, 15124 distinct ids)."""
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f".{kind}.lock"
    handle = path.open("w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(f"another collect-metrics.py {kind} is running ({path})")
    handle.write(f"{os.getpid()}\n")
    handle.flush()
    return handle  # kept alive for the process lifetime; closing releases it


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    runs = sub.add_parser("runs")
    runs.add_argument("--since", help="stop once runs are older than YYYY-MM-DD")
    runs.add_argument("--limit", type=int, help="stop after N new runs")
    runs.add_argument("--refresh", action="store_true",
                      help="re-fetch runs already stored with a null conclusion")
    images = sub.add_parser("images")
    images.add_argument("--packages", help="comma-separated; default is the published set")
    sub.add_parser("artifacts")
    sub.add_parser("all")
    args = ap.parse_args()

    held = []
    if args.cmd in ("runs", "all"):
        held.append(lock("runs"))
        collect_runs(getattr(args, "since", None), getattr(args, "limit", None),
                     getattr(args, "refresh", False))
    if args.cmd in ("artifacts", "all"):
        held.append(lock("artifacts"))
        collect_artifacts()
    if args.cmd in ("images", "all"):
        held.append(lock("images"))
        pkgs = getattr(args, "packages", None)
        collect_images(pkgs.split(",") if pkgs else DEFAULT_PACKAGES)


if __name__ == "__main__":
    main()
