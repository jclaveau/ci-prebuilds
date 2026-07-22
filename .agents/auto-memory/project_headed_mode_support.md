---
name: project_headed_mode_support
description: How headed (headless:false) browser support works per-browser on Alpine — FF free (gtk3 already linked), WK a bundled-gtk4 fix, chromium needs a separate full-chrome build. Plus the conformance headed-leg pattern.
metadata:
  type: project
---

Headed mode splits three ways by cost (2026-07-22 campaign):

**Firefox — FREE (shipped, CI-green).** FF from-source builds a full headed
binary (links gtk3, ~16MB, unavoidable — no gtk-less FF build; headless drags it
too). Xvfb is already wired for the whole FF conformance leg. Headed = one lever:
`--headed` on the `npx playwright test` line flips `headless:!headed` in
`tests/library/playwright.config.ts` for ALL projects. The headed-only tests live
in `headful.spec.ts` (whole-file `it.skip(({headless})=>headless)`, ~16 tests).
DON'T flip the whole suite (drops ~20 `!headless` tests). Pattern in
`conformance/run.sh`: a `run_headed` leg runs `headful.spec.ts --headed`
UNSHARDED once (shard 1), gated by `HEADED_ENABLED` (firefox=1, others=0). No
aggregator change (summary gates on shard result; RC_HEADED joins the gate).

**WebKit — a bundle fix, not a rebuild.** Headed = minibrowser-gtk (gtk4). The
SIGSEGV was the bundled gtk4 stack, fixed in bundle-dist (exclude gtk4 closure →
consumer apk gtk4.0). See [[webkit-gtk-headed-recursion]] (RESOLVED). Consumer
must `apk add gtk4.0`.

**Chromium — a SEPARATE full-chrome build.** chrome-headless-shell CANNOT go
headed (headless-only binary). Need `ninja chrome` (full browser) as a second
artifact — PW itself ships `chromium` + `chromium-headless-shell` separately.
See [[project_chromium_variant_build]]. Multi-day build. Consumer path
`chromium-<rev>/chrome-linux/chrome` (vs `chromium_headless_shell-<rev>/…`).

**Size facts:** FF gtk3 ~16MB (both modes). PW chromium 161MB vs headless-shell
101MB (~1.6×). WK ships minibrowser-wpe (headless) + minibrowser-gtk (headed)
both. Run headed under Xvfb (X11 default); no compositor needed for the tests.
[[feedback_diagnose_before_accepting_cant_fix]]
