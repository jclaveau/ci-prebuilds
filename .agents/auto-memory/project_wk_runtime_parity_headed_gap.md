---
name: project_wk_runtime_parity_headed_gap
description: conformance-runtime-parity's first red on webkit was the headed leg Alpine cannot run (WPE-only artifact), -14 headed + -1 needs-headed grep-invert; RESOLVED by comparing shared suites and counting needs-headed toward Alpine's skip titles
metadata:
  type: project
---

`conformance-runtime-parity` went red for the first time on webkit in run
35972784207 (main, toolchain epoch 2026-09-24): Alpine 5781 passed vs Ubuntu
5796, Δ −15, **0 failed on either side**. The whole delta is shard 1 and it is
structural:

- **−14** — Ubuntu shard 1 reports `suite=headed passed=14`; Alpine reports no
  `headed` row at all, on any of the 20 shards. `conformance/run.sh` sets
  `HEADED_ENABLED=0` for webkit when `/ms-playwright/webkit-*/minibrowser-gtk/MiniBrowser`
  is absent, and it is absent because `build_webkit_gtk` is off by default.
- **−1** — Alpine's library leg runs `--grep-invert` with one pattern more than
  Ubuntu's (`should throw a friendly error if its headed and there is no xserver
  on linux running$`, from the needs-headed skip-list), so it runs 115 tests to
  Ubuntu's 116.

**Why it never fired before:** the two legs run on their own schedules. Every
earlier main run read `webkit | 0/0/0 | 0/0/0 | — (neither side ran)`. This is
the first run where an Alpine webkit conformance and an Ubuntu webkit baseline
were both present.

**RESOLVED** 2026-09-24 on `fix/parity-gate-compare-shared-suites`, both halves
by the same ruling (jean: "we don't need wk with gtk currently, why would we
compare it?"):

- **−14** — `check-runtime-parity.sh` now sums per (browser, suite) and compares
  only suites both sides ran, the rule it already applied one level up for a
  browser absent from a side. Every dropped suite is named under the table, so a
  suite that vanishes for a bad reason does not look like the headed leg.
- **−1** — `skip-list-ubuntu/webkit.titles.txt` carries the xserver title, and
  `check-skip-parity.sh` counts `<b>.needs-headed.titles.txt` toward Alpine's
  titles. Folding that title into `skip-list/webkit.titles.txt` instead would
  have satisfied the superset rule by skipping it unconditionally, killing the
  property that a GTK build still runs it.

**How to apply:** a suite or capability-gated title missing from one side is
"never built", not "regressed" — the gates encode that now, so a NEW parity red
is a real one. Do not read either exclusion as a licence to widen them: both
carry unit tests pinning that a shortfall inside a shared suite still fails and
that an uncovered title still fails beside a covered one. Related:
[[project_webkit_strip_gtk_gate_promote]], [[project_wk_camera_mic_and_noxserver_dispositioned]].
