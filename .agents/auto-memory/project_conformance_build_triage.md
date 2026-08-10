---
name: project_conformance_build_triage
description: How to verify a browser build passed conformance before shipping it — and the traps (conformance is dispatch-gated so recent runs skip it; a rev tag can point to a stale OR fresh build; a "failure" summary is often a since-closed skip-list/harness gap).
metadata:
  type: project
---

Jean's gate: **ensure a build passed conformance before consuming it.** The
conformance jobs (`conformance-{chromium-headless-shell-from-source,firefox,webkit}`)
are **dispatch/label-gated**, so publishes/PRs SKIP them — recent runs give no
fresh proof. The last real run for a given build may be weeks old.

**Triage recipe (cheap, no CI):**
1. Find the run that BUILT the image (`gh run list --commit <sha>`); the build's
   commit is in the image label `org.opencontainers.image.revision` (`docker
   inspect`). A rev tag (`ff-1522`, `wk-2287`) can be STALE or FRESH — always
   check the label's `created` + `revision` (pin-only-tag class,
   [[project_ff_prebuilt_base_pin_only_tag_staleness]]).
2. Read the conformance summary in that run (`gh run view --json jobs`). A
   `summary=failure` is usually 1 shard / a handful of tests, not broad breakage.
3. Get the failing test names from the **run-logs ZIP** (`/actions/runs/<id>/logs`),
   file `NN_conformance-… _ shard (N).txt` — the job-logs API drops the big test
   output ([[reference_gh_run_tests_log_via_zip]]). Strip ANSI (`\x1b\[[0-9;]*[A-Za-z]`).
4. For each failure, decide: (a) now title-skipped on current main skip-list
   (`conformance/skip-list/*.titles.txt`) → not a gap; (b) a harness bug since
   fixed (e.g. WebKit bwrap env typo in pw-conformance.yml); (c) a source bug
   fixed in a LATER build → check the tag's build postdates the fix.

**2026-07-29 verdict (PW 1.60.0):** chs-fs-edge (07-17) — 1 red = `oopif
re-connect CDP`, a PW-intended full-chrome test now title-skipped; binary clean.
ff-1522 = today's 0baf9cec (location-patch present). wk-2287 = 07-22, postdates
the 07-18 soup-mkdir + bwrap-typo fixes. All three cleared.

The rigorous alternative to triage = a conformance-only-vs-stable-tag run, which
doesn't exist yet ([[project_conformance_only_dispatch_gap]]).
