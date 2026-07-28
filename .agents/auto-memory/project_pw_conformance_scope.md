---
name: pw-conformance-scope-out-of-scope
description: SUPERSEDED 2026-07-20 — cli-codegen + trace-viewer were STALE skips, not out-of-scope; re-probed green on the bundled-chromium runner and un-skipped (~170 tests/browser on CHS + FF).
metadata:
  type: project
---

**SUPERSEDED 2026-07-20.** The "out of scope, never chase" verdict below was WRONG —
codegen + trace-viewer were STALE skips, not unrunnable tooling. Re-probed on
chs-prepared:local (bundled-chromium runner + `xvfb-run -a`): all 7 codegen files
pass (~59 tests, 0 fail), trace-viewer 102/104, trace-viewer-scrub 9/9. Un-skipped on
BOTH chromium + firefox (commit b057279); conformance-chromium 29776539019 AND
conformance-firefox 29776540998 BOTH 20/20 GREEN. Only residual title:
`should filter actions by text` (trace-viewer, 1 deterministic fail). The "zero-bytes
codegen subprocess" root cause was an OLD-runner artifact — the current runner's chromium
bundle runs the recorder-UI fine, and codegen is browser-AGNOSTIC (records via bundled
chromium, not the browser-under-test), so FF mirrored CHS with zero extra residuals.
WK gets the same un-skip once its rebuild lands. Lesson: re-probe the LIVE artifact before
trusting ANY "out of scope / structural" skip — same stale pattern as
[[project_conformance_structural_was_stale]]. The generation-vs-viewer distinction below
is still TRUE (tracing.spec.ts = generation, in-scope) but did NOT justify skipping the
viewer — the viewer runs fine too.

--- ORIGINAL (now-superseded) RATIONALE ---

This suite exists to certify the musl-built **browser binaries** (chromium-headless-shell / FF / WK) are drop-in PW-compatible. Two big test families do NOT test the browser and are permanently skipped BY DESIGN, not as a gap:

- **cli-codegen-\<lang\>** (~216 across 3 browsers) — validates PW's code-GENERATION tooling (record → python/js/csharp/java source strings) via an internal recorder-UI chromium subprocess. Confirmed root cause (probe iter 29503931312): the `node cli.js codegen` subprocess writes zero bytes (`Received string: ""` + poll timeout) — its own recorder-UI launch is broken, separate from the main-process `_enableRecorder` (which the [[recorder-family-chromium-bundle]] fixed). A ~4h subprocess-env fix exists but adds zero browser signal.
- **trace-viewer{,-scrub}** (~360 across 3 browsers) — validates the trace VIEWER UI (`npx playwright show-trace` / `showTraceViewer()` — a headed chromium app rendering a recorded trace for a human). Interactive inspection tooling, NEVER invoked during an automated run.

**The load-bearing distinction (trace GENERATION vs VIEWING):** trace *generation* — recording a trace DURING a run via `context.tracing.start()` / `--trace on` — is `tests/library/tracing.spec.ts`, is NOT skipped, and passes. That's the CI-relevant capability. The *viewer* is post-hoc tooling. Same generation-vs-tooling split applies to codegen (recorder records fine; the codegen CLI is tooling).

**Why it matters:** discounting these ~576 out-of-scope tests, real browser-conformance parity is ~94% FF / ~94% WK / ~90% CHS-fs — much closer than raw pass% suggests. Recovering them (5-10h from-source-148 chromium bundle for trace-viewer; subprocess-env fix for codegen) is pass%-inflation with zero signal — same anti-pattern as chasing the pixel-screenshot cluster.

**How to apply:** when a big skip bundle looks tempting, first ask "does this exercise the browser-under-test, or PW's own recorder/viewer/codegen tooling?" If tooling → out of scope, document + skip, don't chase. User endorsed this framing 2026-07-16.

Related: [[recorder-family-chromium-bundle]], [[pw-conformance-visibility-cluster]].
