---
name: chromium-drift-warning-pattern
description: 3-tier drift surfacing — bake `.version-drift-warning` file in producer artifact, echo at consumer build to stderr, prepend `:warning:` block to on-demand issue comment
metadata:
  type: project
---

**Tier 1 — producer bakes warning file** (`playwright/alpine-browsers/chromium-headless-shell/Dockerfile.apk`):
- `ARG EXPECTED_CHROMIUM_VERSION` (passed by producer workflow from `fetch-pw-browsers-json.sh`).
- Drift-check RUN: compare `chrome --version` to expected on first 3 dot-segments.
- On mismatch: `printf '... expected: %s\n actual: %s ...' > /chrome-headless-shell-linux64/.version-drift-warning`. Build still succeeds — drift is silent at PW SDK launch (path-name match suffices), warning is the only signal.

**Tier 2 — consumer echoes at build** (`playwright/Dockerfile.alpine`):
- After `COPY --from=chs-source`, the same RUN that creates `INSTALLATION_COMPLETE` checks for `.version-drift-warning` and `cat`s it to **stderr** so it appears in CI build logs.

**Tier 3 — on-demand surfaces in issue comment** (`on-demand-build.yml` `comment-close` job):
- `detect-chromium-drift` step pulls one alpine playwright tag, reads the warning file, emits as step output.
- Success-comment step prepends `:warning: **Chromium version drift in the alpine variants**` block when drift present.

**Why:** alpine:edge ships latest chromium, not whatever PW pinned — see [[project_alpine_no_historical_apk_archive]]. Silent ship is wrong (tests on version-sensitive APIs may surface differences). Hard-fail is wrong too (most tests don't care about patch drift). Soft warning lets the requester decide.

**How to apply:** Symmetric mechanism for FF when it ships on alpine — same `.version-drift-warning` file convention. If extending to other browsers, keep the comparison at 3 dot-segments (major.minor.patch) — finer-grained false-positives constantly because of alpine's `-rN` postfix.
