---
name: feedback_bench_in_ci_not_laptop
description: perf measurements and attribution A/Bs run in CI (public repo, free minutes, the CPUs that matter), never on jean's laptop; the laptop is for smoke and tooling checks only
metadata:
  type: feedback
---

Every benchmark, perf probe and attribution A/B runs in GitHub Actions: an existing probe
workflow (perf-probe.yml, alpine-gap-probes.yml…) or a new dispatchable one committed to
main, arms interleaved on one runner, CPU model recorded. The laptop (i5-8350U, shared with
other sessions) is only for quick smoke checks and getting the tooling right.

**Why:** jean, 2026-10-29: "why don't you run the bench in ci?" after agents were sent to
time WebKit launch and pnpm install locally. The repo is public, so minutes are free; the
laptop is noisy, serialises agents behind a lock, and is not the hardware consumers run on.
Laptop A/Bs had already disagreed with CI (local 1.04 residual vs CI 0.98-1.00).

**How to apply:** when briefing a probe agent or planning a measurement, put it in CI from
the start. Never copy a private repo's files (e.g. Planner's lockfile) into this public repo
to make a CI fixture; use a public or generated workspace. See [[project_wk_ubuntu_launch_real_1_10]].
