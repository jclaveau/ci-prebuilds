---
name: project_transient_fetch_reads_as_code_fault
description: a network transient in fetch-aports.sh fails the whole build and reports the CHANGED file's Dockerfile line, so it reads as a code fault; and two arms of an A/B dispatched together share one outage window, so both die at once
metadata:
  type: project
---

2026-08-27: both firefox builds of a paired A/B (33087229919 packaging-only,
33087244587 packaging+LTO) failed within seconds of each other. Neither was a
code fault:

    curl: (28) Connection timed out after 20002 milliseconds
    (fetch-aports.sh, all three retries exhausted, GitLab unreachable)

**Why it misleads.** `fetch-aports.sh` has its OWN retry loop, so exhausting it
returns non-zero and BuildKit reports the failure against the `RUN` line of the
Dockerfile — which, on a branch that changed a build script, is the changed
file. The summary therefore points at your diff while the cause is the network.
The coordinator nearly attributed this to the packaging change before reading
the step output. **Read the failing STEP's output, never the job summary or the
Dockerfile line, before attributing a build failure to your own change.**

**A step having internal retries does not make the build resilient** — it only
moves the failure later. Three 20 s curl attempts against an outage lasting
minutes is a guaranteed loss.

**The A/B-pair lesson is the sharper one.** Dispatching the control and the arm
simultaneously is right for CPU/runner variance — that is why they are a pair —
but it gives them a SHARED infrastructure window, so an upstream outage takes
both. Correlated failure is the price of the correlated environment that makes
the comparison valid. Do not read "both arms failed identically" as evidence
about the code; check whether they failed at the same clock time first.

**Recovery is cheap and preserves the pairing:** `gh run rerun --failed <id>`
on each restarts only the failed jobs in place
([[project_gh_run_rerun_single_job]]), and the re-run pair lands in a new shared
window, which is what the comparison needs anyway.
