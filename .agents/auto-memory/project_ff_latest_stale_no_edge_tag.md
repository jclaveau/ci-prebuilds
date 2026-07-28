---
name: project_ff_latest_stale_no_edge_tag
description: The `ff-latest` moving tag is main-gated so it goes STALE on feature branches (unlike wk-edge/chs-fs-edge which promote per-branch) — firefox conformance dispatches on a branch must target the fresh `sha-<gitsha>` build, not ff-latest.
metadata:
  type: project
---

`promote-firefox` (playwright-alpine-browsers.yml:643) is gated
`if: github.event_name=='push' && github.ref=='refs/heads/main'`. All firefox
work lives on `feat/webkit-alpine-branch-c`, which only pushes **sha-tagged**
images — so the moving `ff-latest` / `ff-<rev>` / `ff-<ver>` tags last advanced
on the most recent *main* FF build (was **2026-06-05**, BuildID 20260605070758),
months behind the branch. **Asymmetry:** WebKit (`wk-edge`) and chromium
(`chs-fs-edge`, `:edge`) HAVE branch-promoted `-edge` tags → their conformance
dispatches on the branch get fresh builds. Firefox has **no `-edge` tag**, only
main-gated `ff-latest`.

**How it bit (2026-07-27):** dispatched full-headed FF conformance
(`HEADED=1`) against `ff-latest` → 13/20 shards failed with
`TypeError: Cannot read properties of undefined (reading 'url')`. That is the
[[project_ff_juggler_pageerror_musl_gap]] crash: Juggler emits
`pageUncaughtError` with **no `location`** on the UNPATCHED build, and PW's
context PageError dispatcher reads `location.url` unconditionally
(coreBundle.js:49624 ← emitOnContext ← addPageError ← FFPage._onUncaughtError).
The 07-20 patch (apply-and-build.sh threads `location` through Juggler
Runtime.js/PageAgent.js/Protocol.js) fixes it — PageAgent.js:271 `location,` —
but that patch only exists in the branch's **sha** builds, never promoted to
ff-latest. Re-dispatched against the patched `sha-ef541ad5…` (BuildID
20260720131406) → **19/20 green** (the 1 residual = a transient
`curl … githubusercontent.com` exit-35 SSL flake in the runner build, not a
test). So headed FF was NOT a browser gap and needed NO rebuild — just the
right image.

**Timing nuance (why headless CI stayed green):** the crash is an async
unhandled rejection from the WebError path; headless is fast enough that it
fires after the test ends, headed's slower render surfaces it mid-test (+ headed
adds favicon-404 page errors). Reproduces in BOTH modes on the unpatched build;
glibc reference FF (headed+headless) never omits location → 0 rejections
(decisive parity check: our-gap, not stock-PW).

**How to apply:**
- On a feature branch, dispatch FF conformance against the branch's fresh
  `sha-<gitsha>` (or the producer's embedded `conformance-firefox` leg, which
  already uses `sha-${{ github.sha }}`), NOT `ff-latest`. `ff-latest` self-heals
  on merge-to-main.
- Before trusting any moving tag, verify the artifact: `docker … platform.ini`
  BuildID + unzip omni.ja `*/PageAgent.js` and grep the emit for `location,`.
- **Proposed durable fix (ask jean first):** add a branch-promoted `ff-edge` tag
  symmetric with `wk-edge`/`chs-fs-edge` so FF branch dispatches get fresh
  builds. [[project_multijob_base_image_audit]] [[feedback_verify_pkg_names_locally]]
