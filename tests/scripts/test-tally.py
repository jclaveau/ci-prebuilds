#!/usr/bin/env python3
"""Unit test for tally's build forecast: `build_eta` and the poll delay built
on it.

Exists because the forecast is what a watcher sleeps on. Predicting the tail of
a chromium chain by repeating the CURRENT round's duration reads ~63 h for a
chain that really takes ~36: rounds r8-r12 are link-only, minutes not hours,
and only the profile knows that. Every case below pins a shape the arithmetic
must keep: the profile supplies the shape, the run supplies the pace.

Runs against no network -- `build_eta` takes a job list, never a run id.
"""
import datetime as dt
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "scripts"))
import tally  # noqa: E402

NOW = dt.datetime(2026, 9, 25, 12, 0, 0, tzinfo=dt.timezone.utc)
# Two full rounds then a link-only tail, the shape every real chain has.
PROFILE = {"setup": 600, "r1": 10_000, "r2": 10_000, "r3": 1_000, "finalize": 600}

failures = 0
checks = 0


def check(label, got, want):
    global failures, checks
    checks += 1
    if got != want:
        print(f"FAIL: {label} — got {got!r}, wanted {want!r}", file=sys.stderr)
        failures += 1


def near(label, got, want, tol=1.0):
    check(label, got is not None and abs(got - want) <= tol, True)
    if got is not None and abs(got - want) > tol:
        print(f"      {got!r} is more than {tol} from {want!r}", file=sys.stderr)


def at(minutes_ago):
    return f"{NOW - dt.timedelta(minutes=minutes_ago):%Y-%m-%dT%H:%M:%SZ}"


def stage_job(stage, status, conclusion, started=None, ended=None):
    return {"name": tally.CHS_JOB + {"setup": "-setup", "finalize": ""}.get(stage, f"-{stage}"),
            "status": status, "conclusion": conclusion,
            "started_at": started, "completed_at": ended}


# ----------------------------------------------------------------- chs_stage

check("setup job", tally.chs_stage(tally.CHS_JOB + "-setup"), "setup")
check("round job", tally.chs_stage(tally.CHS_JOB + "-r7"), "r7")
check("finalize job", tally.chs_stage(tally.CHS_JOB), "finalize")
check("another browser", tally.chs_stage("build-firefox"), None)
check("unnumbered suffix", tally.chs_stage(tally.CHS_JOB + "-rX"), None)

# ------------------------------------------------------------------ run_pace

# Weighted by the profile, so the 1000 s stage cannot outvote the 10000 s one:
# (11000 + 500) / (10000 + 1000) = 1.045, not the unweighted (1.1 + 0.5) / 2.
pace_stages = {
    "r1": stage_job("r1", "completed", "success", at(600), at(600 - 11_000 / 60)),
    "r3": stage_job("r3", "completed", "success", at(400), at(400 - 500 / 60)),
}
near("pace is weighted by the profile", tally.run_pace(pace_stages, PROFILE), 11_500 / 11_000, 0.001)

check("a failed stage is not a measurement",
      tally.run_pace({"r1": stage_job("r1", "completed", "failure", at(600), at(400))}, PROFILE), 1.0)
check("a running stage is not a measurement",
      tally.run_pace({"r1": stage_job("r1", "in_progress", None, at(600))}, PROFILE), 1.0)
check("a stage outside the profile is not a measurement",
      tally.run_pace({"r9": stage_job("r9", "completed", "success", at(600), at(500))}, PROFILE), 1.0)
check("nothing finished yet", tally.run_pace({}, PROFILE), 1.0)

# ----------------------------------------------------------------- build_eta

# r1 took 11000 s against a 10000 s budget: pace 1.1. r2 started 5000 s ago, so
# 10000 * 1.1 - 5000 = 6000 s left in the round, and the rest of the chain is
# the PROFILE's tail at that pace -- r3 + finalize, 1600 s, NOT another 11000.
chain = [
    stage_job("setup", "completed", "skipped"),
    stage_job("r1", "completed", "success", at(11_000 / 60 + 5000 / 60), at(5000 / 60)),
    stage_job("r2", "in_progress", None, at(5000 / 60)),
    {"name": "build-firefox", "status": "completed", "conclusion": "skipped",
     "started_at": None, "completed_at": None},
]
eta = tally.build_eta(chain, NOW, PROFILE, {})
check("the running round is the stage", eta["stage"], "chs r2")
check("finished rounds are counted", eta["done"], 1)
near("elapsed is measured from the round's start", eta["elapsed"], 5000)
near("pace comes from the run's own rounds", eta["pace"], 1.1, 0.001)
near("the round's own budget is scaled by the pace", eta["boundary_left"], 6000)
near("the tail is the profile's, not a repeat of this round",
     eta["chain_left"], 6000 + 1.1 * 1600 + tally.CONFORMANCE_TAIL)

# The bug this file exists for: predicting the tail from the current round.
check("the tail is not charged a full round per stage",
      eta["chain_left"] < 6000 + 2 * 10_000, True)

# A chain with a skipped setup must not report the skip as a finished stage.
check("a skipped stage is not counted as done",
      tally.build_eta([stage_job("setup", "completed", "skipped"),
                       stage_job("r1", "in_progress", None, at(60))],
                      NOW, PROFILE, {})["done"], 0)

# A firefox-only dispatch still carries every chromium job, skipped. Reading
# those as a chain reported "chs between jobs 0/14" for a run with no chromium
# in it, and hid the job that WAS running.
skipped_chain = [stage_job(s, "completed", "skipped") for s in ("setup", "r1", "r2", "finalize")]
check("an all-skipped chromium chain is not the run's story",
      tally.build_eta(skipped_chain + [{"name": "build-firefox", "status": "in_progress",
                                        "conclusion": None, "started_at": at(100),
                                        "completed_at": None}],
                      NOW, PROFILE, {"build-firefox": [10_000]})["stage"], "build-firefox")

between = tally.build_eta([stage_job("r1", "completed", "success", at(600), at(400))], NOW, PROFILE, {})
check("a chain between two rounds has no forecast", between["chain_left"], None)
check("a chain between two rounds says so", between["stage"], "chs between jobs")
check("a finalized chain is in its conformance tail",
      tally.build_eta([stage_job("finalize", "completed", "success", at(600), at(400))],
                      NOW, PROFILE, {})["stage"], "chs conformance")

# A plain build job predicts off past successes, and its round IS its chain.
ff = [{"name": "build-firefox", "status": "in_progress", "conclusion": None,
       "started_at": at(100), "completed_at": None}]
ff_eta = tally.build_eta(ff, NOW, PROFILE, {"build-firefox": [240, 10_000]})
check("a plain job is named by its job", ff_eta["stage"], "build-firefox")
near("a plain job predicts off the next success above its elapsed",
     ff_eta["boundary_left"], 10_000 - 6000)
check("a plain job's boundary is its chain end", ff_eta["chain_left"], ff_eta["boundary_left"])

longest = tally.build_eta(ff, NOW, PROFILE, {"build-firefox": [240, 600]})
check("a job past every past success has no ETA", longest["chain_left"], None)
check("a job past every past success reports its longest", longest["longest_past"], 600)
check("a job with no history at all reports nothing",
      tally.build_eta(ff, NOW, PROFILE, {})["longest_past"], None)

check("a run with no job started yet is queued",
      tally.build_eta([], NOW, PROFILE, {})["stage"], "queued")

# The chromium chain wins over a conformance shard running beside it.
check("a chain is read as a chain, not as its shards",
      tally.build_eta(chain + [{"name": "conformance-chromium-3", "status": "in_progress",
                                "conclusion": None, "started_at": at(30), "completed_at": None}],
                      NOW, PROFILE, {})["stage"], "chs r2")

# -------------------------------------------------------------- wakeup_delay

low, high = tally.WAKEUP_BOUNDS
check("a boundary hours out sleeps the maximum", tally.wakeup_delay(9000), high)
check("a boundary just inside the cap is capped", tally.wakeup_delay(high - 60), high)
check("a near boundary is slept to just past it",
      tally.wakeup_delay(720), 720 + tally.WAKEUP_SLACK)
check("a boundary already passed still sleeps the minimum", tally.wakeup_delay(-600), low)
check("the slack lands past the boundary, never short of it",
      tally.wakeup_delay(600) > 600, True)

# ------------------------------------------------------------ remaining_seconds

check("the next success above the elapsed time", tally.remaining_seconds([240, 10_000], 300), 9700)
check("the warm cluster while it is still plausible", tally.remaining_seconds([240, 10_000], 100), 140)
check("nothing left above the elapsed time", tally.remaining_seconds([240, 10_000], 20_000), None)
check("no history to predict from", tally.remaining_seconds([], 100), None)

print(f"tally: {checks - failures}/{checks} checks passed")
sys.exit(1 if failures else 0)
