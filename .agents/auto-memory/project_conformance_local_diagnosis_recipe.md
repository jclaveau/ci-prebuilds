---
name: project_conformance_local_diagnosis_recipe
description: How to root-cause a conformance skip locally (no CI cycle) — build the prepared image from a published artifact + run the ONE failing test isolated. Per-browser launch flags + the mandatory npm-run-build step.
metadata:
  type: project
---

To deep-diagnose a conformance title WITHOUT a ~40min CI dispatch or a multi-hour rebuild:

1. `docker pull ghcr.io/jclaveau/playwright-alpine-browsers:<artifact-tag>`
2. Build the runner (env-driven `build-runner.sh`):
   `BROWSER=<b> IMAGE_REF=<full-ref> ARTIFACT_REV=<rev> PW_VERSION=1.60.0 \
    IMAGE_TAG_OUT=<b>-runner:local bash playwright/alpine-browsers/conformance/build-runner.sh`
   (get IMAGE_REF/ARTIFACT_REV from a conformance job's env: grep the job log for
   `IMAGE_REF:` / `ARTIFACT_REV:`.)
3. Bake prepared (mirrors run.sh): run the runner and
   `git clone --depth 1 --branch v1.60.0 https://github.com/microsoft/playwright.git /pw-src
    && cd /pw-src && npm ci --no-audit --no-fund --prefer-offline && npm run build`
   then `docker commit <container> <b>-prepared:local`. **`npm run build` is MANDATORY** —
   skip it and every config-load dies on `Cannot find module
   @playwright/experimental-ct-core/lib/program.js` (looks like a test failure, isn't).
4. Run one test isolated:
   `docker run --rm <FLAGS> -v probe.sh:/d.sh <b>-prepared:local sh /d.sh` →
   `cd /pw-src && xvfb-run -a npx playwright test --config=tests/library/playwright.config.ts
    --project=<b>-{library,page} <spec> -g "<title>" --reporter=line --retries=0`.

**Per-browser launch flags (else the browser won't run):**
- FF: sed the config to add `args: browserName==="firefox" ? ["--remote-debugging-port=0"] : undefined`
  (juggler handshake). Map a title→file with `grep -rlF "'<title>'" tests/page tests/library`.
- WK: needs the FULL sandbox strip or it dies `browserContext.newPage: Browser closed` —
  `--security-opt seccomp=unconfined --security-opt apparmor=unconfined --cap-add SYS_ADMIN
   --cap-add NET_ADMIN -e WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 -e WEBKIT_FORCE_SANDBOX=0`.
- chromium: `--security-opt seccomp=unconfined` is enough.

**Modernizr keys are usually missing runner FONTS, not browser gaps:** emoji→`font-noto-emoji`,
`unicoderange`→`font-liberation` (Modernizr uses `@font-face{src:local("Arial")}`; fontconfig
aliases Arial→Liberation Sans). Add the apk to the runner + re-run; no rebuild.

[[project_conformance_remaining_skips_dispositioned]] [[feedback_diagnose_before_accepting_cant_fix]]
[[project_ff_genuine_deltas_mostly_stale]]
