---
name: conformance-structural-was-stale
description: 2026-07-19 session — nearly EVERY "structural / needs a rebuild" conformance verdict turned out to be a stale APK-era carryover that passes on the from-source binary, or a missing additive runner-config. Re-probe on the current artifact BEFORE documenting anything structural.
metadata:
  type: project
---

A single session took Alpine PW-conformance browser-only parity from ~90-92% to
**CHS 99.6% / WK 99.7% / FF 95.3%** — ~400 tests recovered, almost entirely
WITHOUT browser rebuilds. The throughline: **"structural" verdicts were wrong.**

Every cluster previously documented structural / needs-a-WebKit-build-flag /
needs-a-chromium-rebuild fell to one of two cheap causes:
- **Stale APK-era carryover.** Skips were seeded against the old apk
  chromium-headless-shell (broken pak, appearance:none UA stylesheet, subset
  build) and NEVER re-probed once the pipeline moved to from-source chromium 148.
  From-source ships the full chrome_100_percent pak + its own Skia/BoringSSL →
  the skips just pass. Recovered this way: drag/wheel/drop, tap, video,
  screencast, form-controls, hit-target geometry, UA-stylesheet titles,
  **pixel-golden screenshots (+103 at threshold:0 — from-source Skia renders
  pixel-identical to PW's Ubuntu goldens; golden name has no platform suffix)**,
  slowmo, accname/axe, local-fonts, security-details/http2, proxy, SAB.
- **Missing additive runner-config** (env/apk, no rebuild, ZERO blast radius):
  `GST_PLUGIN_SYSTEM_PATH_1_0` recovered ALL WK media + recordVideo/screencast
  (empty gst registry, decoders installed≠discovered — corrected a 3x-wrong
  "structural" verdict); `ffmpeg-libs` → FF H.264; `icu-data-full` → locale.

**How to apply:** BEFORE writing "structural" / "needs a rebuild" in a skip-list,
re-probe the exact spec file against the CURRENT published artifact
(`build-runner.sh` + a local `docker run … npx playwright test <file>
--retries=2`). Assume a skip is stale until a probe on the live binary proves the
gap. A pixel/threshold:0 skip is NOT automatically structural — from-source
browsers bundle their own renderer and match upstream goldens. Only conclude
structural after: (a) probe fails on the live artifact, AND (b) the fix is a
genuine source/build change, not an additive apk/env. Prefer additive
runner-config over behavior toggles ([[feedback_unskip_regression_beyond_target]]
— FF fission-off regressed untargeted tests).

**Two more traps found 2026-07-20 (FF deep-dive):**
- **A skip seed can predate a fix that would've prevented it.** The FF title-skip
  seed (run 28952021038, 2026-07-08) was taken ONE DAY before the playwright.cfg
  placement fix (2026-07-09, the `+56` recovery). So the seed FF had NO cfg at all
  → every cfg-pref-dependent test (pdfjs, cookieBehavior, https-first, etc) failed
  and got skipped. ~39 of the ~90 FF titles were stale THAT way — they pass now
  that the runner curls playwright.cfg. Always check whether a skip predates a
  since-landed runner/build fix before trusting it.
- **A crashing test can CASCADE and poison whole shards.** FF
  `page-event-pageerror` fails with a client-side `.url`-undefined crash that
  prints "Test ended" and kills the worker → EVERY subsequent test in that worker
  fails too. So a bulk un-skip probe reds far more than the real gaps (13-14/20
  shards) and you cannot read stale-vs-genuine from it. FIX: either keep the
  cascade source skipped during the probe (skip pageerror → the rest reads clean),
  or run each file in its OWN `npx playwright test <file>` invocation (per-file
  isolation stops one file's crash from touching another). Isolated per-file
  probe: console 16 / har 56 / fetch 110 / page-goto 62 / base-url 8 — all green,
  proving the bulk stale while pageerror alone is genuine.

**Genuine-structural remainder (probed, real):** FF page-event-pageerror musl
crash ([[project_ff_juggler_pageerror_musl_gap]]), FF cross-process/CORS/HAR/
detached error-string deltas, FF+WK browsertype-connect hang
([[project_ff_browsertype_connect_hang]]), WK remote-video, CHS
executablePath-path-shape + oopif-CDP-reconnect timing, WK modernizr Safari-UA
delta, out-of-scope PW tooling (codegen/trace-viewer). Cousin of
[[feedback_config_first_layered_diagnosis]], [[project_wk_media_gst_registry_env]].
