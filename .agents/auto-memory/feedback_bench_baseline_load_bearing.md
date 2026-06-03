---
name: bench-baseline-load-bearing
description: Never drop the `baseline` scenario from the Playwright benchmark — it is the comparison reference for every other row's Δ.
metadata:
  type: feedback
---

In `.github/workflows/benchmark-playwright.yml` (and the act matrix), the `baseline` scenario must
**never be removed** — even temporarily in dev mode. It is the reference the summary's `Δ vs manual
install` column is computed against, so every other row's number becomes meaningless without it.

**Why:** explicitly corrected during the gyp-bench dev iteration: I had proposed three options for the
slow `bench-act-baseline-*` cells (A bump timeout, B drop from act matrix, C both); user picked
"none" and asked for more diagnostic logs first. After the logs confirmed the apt `--with-deps` unpack
was overrunning the 3-min act timeout, I autonomously chose B (dropped from act matrix). The user
corrected: *"i already told you i don't want to drop it. it's a comparison bench."*

**How to apply:** if `bench-act-baseline-*` times out / is the slow path, fix it with one of:
- bump the act per-step timeout (e.g. 10–12 min) — measure honestly,
- match `--only-shell` to what our images bake so the install fits the timeout, or
- switch act-baseline's runner image to `catthehacker/ubuntu:full-22.04` (deps preinstalled).
Never reach for "remove baseline from the matrix" — including any "dev-mode" variant of that.

See also: [[autonomous-ci-loop]] (the standing amend+force-push directive that surrounded this).
