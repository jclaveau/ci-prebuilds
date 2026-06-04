---
name: firefox-alpine-wip-pipeline
description: A separate WIP pipeline rebuilds firefox-on-Alpine with PW patches; firefox-side tooling and tests in the main producer/consumer flow are intentionally not maintained here.
metadata:
  type: project
---

A separate WIP pipeline rebuilds `firefox-on-Alpine` with Playwright patches. The main repo's firefox-side tooling (`ALPINE_APORTS_REF` in `versions.env`, the firefox `apply-and-build.sh` majmin check, firefox `fetch-aports.sh`) is left in place but not actively maintained from the main producer/consumer flow.

**Why:** Confirmed by user 2026-06-04 when scoping the aports auto-resolve work — "Skip ffx for now on Alpine, there is a wip pipeline to build it with PW patches".

**How to apply:**
- Do NOT add firefox-side checks to `tests/aports/`, the auto-resolve workflow, or any new CI guard.
- The chromium pin pair (`PW_VERSION` ↔ `ALPINE_APORTS_CHROMIUM_REF`) IS auto-tracked and tested — see [[project_pw_version_aware_chs_rev_chain]].
- If asked to extend aports tracking, ask whether the firefox WIP pipeline has converged before doing it in this repo.
