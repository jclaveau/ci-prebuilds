---
name: vanilla-config-test-pw-alignment
description: Alpine vanilla-config test must `pnpm add -D @playwright/test@$PW_VERSION` derived from `playwright --version`, not unversioned (which resolves to LATEST and breaks non-default PW builds)
metadata:
  type: project
---

**Symptom:** PW 1.59.1 build of #36 succeeded at primary `pnpm playwright test` (image baked with `CHS_REV=1217`, SDK installed `playwright@1.59.1`), but failed in the alpine-only vanilla-config regression step:
```
Executable doesn't exist at /ms-playwright/chromium_headless_shell-1223/...
```

**Root cause:** The vanilla-config step did `pnpm add -D @playwright/test` unversioned → npm registry resolved to **latest** (1.60.0) → that PW SDK expected chs-1223, not the chs-1217 the image actually ships.

**Fix (PR 43):** Align the test's PW install to the image's PW:
```yaml
PW_VERSION="$(playwright --version | awk '{print $2}')"
pnpm add -D "@playwright/test@$PW_VERSION"
```
Done before any other vanilla-config setup. `playwright --version` works because the image installs it globally via `pnpm install -g playwright@${PLAYWRIGHT_VERSION}`.

**Why:** Vanilla-config test exists to prove PW SDK's path-based auto-discovery works on the image AS-SHIPPED. Mismatching the test's PW version against the image's PW version makes it a different test — one that asserts forward-compat with latest PW, which we don't claim.

**How to apply:** Any future test that does `pnpm add` of a PW-related package in CI MUST pin to the image's version. Unversioned installs are silent forward-compat assertions.
