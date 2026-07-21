---
name: project_ff_genuine_deltas_mostly_stale
description: FF "genuine musl deltas" (19 titles) deep-diagnosed 2026-07-21 — 17/19 STALE (pass isolated on the fixed FF binary), sole real one (hover/fine-pointer) fixed via a FF pref. No browser-code diff needed.
metadata:
  type: project
---

The 19 titles under "Genuine musl FF deltas" in firefox.titles.txt were NOT genuine.
Deep diagnosis 2026-07-21 (built ff-prepared:local from artifact sha-ef541ad, ran each
title ISOLATED): **17/19 PASS** on the current FF binary. They were restored during the
pageerror-CASCADE era (the `.url`-undefined crash poisoned whole workers → many tests
looked like genuine fails). That crash is fixed (juggler location patch, ef541ad), so the
cascade is gone. Un-skipped (commit dad0a4c), validated under 20-shard load via dispatch.

**Sole genuine one — `should report hover and fine pointer for desktop`** (page-emulate-
media): headless musl FF's LookAndFeel defaults pointer/hover to coarse/none, so
`(hover: hover)` + `(pointer: fine)` don't match on the default desktop context. Ubuntu FF
reports fine+hover by default; PW forces it for chromium via `--blink-settings=primary
HoverType/PointerType` but has NO firefox equivalent. **Fix (validated): FF pref
`ui.primaryPointerCapabilities=6` + `ui.allPointerCapabilities=6`** (6 = eFine|eHover; the
hover bit 4 is required — `2` fine-alone still fails). Applied in build-runner.sh
(01-alpine-pointer.js, no rebuild) + apply-and-build.sh (baked into artifact). Commit a499e4c.

**Local ff-prepared build recipe** (for future FF diagnosis without a CI rebuild):
`docker pull <ff-artifact>` → `BROWSER=firefox IMAGE_REF=<art> ARTIFACT_REV=<rev>
PW_VERSION=1.60.0 IMAGE_TAG_OUT=ff-runner:local bash build-runner.sh` → run `git clone
--branch v<PW> playwright /pw-src && npm ci && npm run build` in it → commit ff-prepared.
The `npm run build` step is MANDATORY (else config-load dies on
`@playwright/experimental-ct-core/lib/program.js`). Then run specs with the FF juggler
`--remote-debugging-port=0` config sed. [[project_ff_juggler_pageerror_musl_gap]]
[[project_conformance_structural_was_stale]] [[feedback_unskip_regression_beyond_target]]
