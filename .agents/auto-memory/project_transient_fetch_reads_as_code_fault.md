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

**Two more instances, same session (2026-09-08), same tell (the clock):**

- Webkit conformance shard 4's runner-image build failed with
  `ERROR: Dependency "nice" not found (tried pkg-config)` — gst-plugins-bad
  rejecting libnice, it looked like. Requirement was `>=0.1.23`, the stage
  builds exactly `0.1.23`, and the whole recipe reproduced clean locally. The
  giveaway: the meson error fired **8.5 s** into the step, far too fast for
  libnice to have actually compiled — so the libnice half never ran. Cause:
  the fetch leg one step up uses `curl | tar`, which swallows a dropped/empty
  body with busybox tar instead of failing; the sibling gst-plugins-bad fetch
  right below it had already been hardened for exactly this in August, this
  one never was. Fixed in #169 (file + `gzip -t` + retry +
  `pkg-config --atleast-version` assert). This failure also blocked
  `promote-webkit` that day — a THIRD distinct blocking mechanism alongside
  the three fixed in [[project_wk_promote_gate_holds_the_nightly_bench]] and
  the GTK-off non-issue — confirming again that promote's gate reads whatever
  conformance reports, with no bias toward "it must be GTK."
- Firefox conformance shard 14 read as a regression on main
  (`conformance-firefox` summary + promote both red) but was
  `npm error code ECONNRESET` inside an `npm install -g` — no test ever ran.
  Found 4 such `npm install -g` sites in the conformance runner with **zero**
  retry configured (npm's own default is 2 attempts / 10 s ceiling, thin
  against a 20-shard fan-out hitting the registry at once). Fixed in #173
  (added npm's built-in retry flag to all four).

**Pattern for idle time:** when parked waiting on a long dispatch, sweeping
main for unrelated red bars keeps finding these — three separate disguised
network failures surfaced in a single session, none of them a real
regression. Read the failing step's output before spending time on the
"regression."
