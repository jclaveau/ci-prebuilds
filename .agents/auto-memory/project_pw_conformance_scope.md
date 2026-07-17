---
name: pw-conformance-scope-out-of-scope
description: cli-codegen + trace-viewer conformance tests are OUT OF SCOPE (validate PW tooling, not the musl browser); never chase them
metadata:
  type: project
---

This suite exists to certify the musl-built **browser binaries** (chromium-headless-shell / FF / WK) are drop-in PW-compatible. Two big test families do NOT test the browser and are permanently skipped BY DESIGN, not as a gap:

- **cli-codegen-\<lang\>** (~216 across 3 browsers) — validates PW's code-GENERATION tooling (record → python/js/csharp/java source strings) via an internal recorder-UI chromium subprocess. Confirmed root cause (probe iter 29503931312): the `node cli.js codegen` subprocess writes zero bytes (`Received string: ""` + poll timeout) — its own recorder-UI launch is broken, separate from the main-process `_enableRecorder` (which the [[recorder-family-chromium-bundle]] fixed). A ~4h subprocess-env fix exists but adds zero browser signal.
- **trace-viewer{,-scrub}** (~360 across 3 browsers) — validates the trace VIEWER UI (`npx playwright show-trace` / `showTraceViewer()` — a headed chromium app rendering a recorded trace for a human). Interactive inspection tooling, NEVER invoked during an automated run.

**The load-bearing distinction (trace GENERATION vs VIEWING):** trace *generation* — recording a trace DURING a run via `context.tracing.start()` / `--trace on` — is `tests/library/tracing.spec.ts`, is NOT skipped, and passes. That's the CI-relevant capability. The *viewer* is post-hoc tooling. Same generation-vs-tooling split applies to codegen (recorder records fine; the codegen CLI is tooling).

**Why it matters:** discounting these ~576 out-of-scope tests, real browser-conformance parity is ~94% FF / ~94% WK / ~90% CHS-fs — much closer than raw pass% suggests. Recovering them (5-10h from-source-148 chromium bundle for trace-viewer; subprocess-env fix for codegen) is pass%-inflation with zero signal — same anti-pattern as chasing the pixel-screenshot cluster.

**How to apply:** when a big skip bundle looks tempting, first ask "does this exercise the browser-under-test, or PW's own recorder/viewer/codegen tooling?" If tooling → out of scope, document + skip, don't chase. User endorsed this framing 2026-07-16.

Related: [[recorder-family-chromium-bundle]], [[pw-conformance-visibility-cluster]].
