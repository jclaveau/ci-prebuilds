---
name: auto-resolve-aports-workflow
description: PR-time GHA workflow that auto-bumps ALPINE_APORTS_CHROMIUM_REF to match Renovate's PW_VERSION bump — pre-flight check exists because resolve script prefix-matches but producer enforces strict equality
metadata:
  type: project
---

`.github/workflows/auto-resolve-aports.yml` reacts to any PR touching `playwright/alpine-browsers/versions.env`, derives `chromium-headless-shell.browserVersion` from `playwright-core@${PW_VERSION}/browsers.json`, calls `chromium-headless-shell/scripts/resolve-aports-ref.sh`, and commits the new SHA back to the PR branch with `[skip ci]` in the subject.

**Load-bearing invariants** (don't refactor away without understanding):
1. **Pre-flight pkgver check** (workflow step `resolve & pre-flight`): re-fetches `aports@${NEW_SHA}/community/chromium/APKBUILD`, parses pkgver, asserts `pkgver == CHS_VER`. This MIRRORS `apply-and-build.sh:43-54`'s strict check at PR time. Reason: `resolve-aports-ref.sh` does a **major.minor.patch PREFIX match** but `apply-and-build.sh` does **strict equality**. Without pre-flight, the workflow happily commits a SHA whose latest aports commit shipped a newer dot-release than PW pins, which the producer would later hard-fail after a 30-min compile.
2. **Loop guard**: `if: github.actor != 'github-actions[bot]'` skips the synchronize event triggered by the workflow's own push. `[skip ci]` in the commit subject prevents test-and-publish.yml's path-filter from firing on the same push.
3. **Firefox is NOT auto-resolved** — see [[firefox-alpine-wip-pipeline]].
4. **YAML block scalar trap**: the commit step uses multiple `git commit -m ...` flags (one per paragraph) instead of a HEREDOC because run-block YAML can't parse multi-line `-m "..."` strings — see [[feedback-gha-multiline-commit-yaml]]. The failure-comment step uses `env: BODY: |` + `${BODY/__RUN_URL__/$RUN_URL}` placeholder substitution for the same reason.

**Tests** (`tests/aports/`):
- `test-resolve-aports-ref.sh` — unit test (happy: 148.0.7778.96 → hex SHA; sad: 999.0.0.0 → exit 2 + "no aports commit found")
- `test-versions-env-consistency.sh` — end-to-end strict pkgver==CHS_VER guard, runs on every PR + push to main via `tests-aports.yml`. Chromium only.

**How to apply:**
- If `resolve-aports-ref.sh` ever changes to do strict (vs prefix) matching, the pre-flight becomes redundant — but don't remove it without verifying both scripts agree; cheap insurance.
- Adding a new aports-tracked package → mirror this exact shape (resolve → pre-flight → awk rewrite → commit with `[skip ci]` → comment on failure). Do NOT extend to firefox.
