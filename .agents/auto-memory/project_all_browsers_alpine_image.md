---
name: project_all_browsers_alpine_image
description: The alpine-{dind,dood}-playwright combined image now stages all THREE musl browsers headless (chromium-headless-shell + Firefox + WebKit-WPE). Wiring pattern + the two musl WebKit gotchas (seccomp + PW host-req false-positive).
metadata:
  type: project
---

`playwright/Dockerfile.alpine` stages all three from the producer image, each at
PW SDK's auto-discovery path — no `executablePath` override:
- chromium-headless-shell → `/ms-playwright/chromium_headless_shell-${CHS_REV}/`
- Firefox → `/ms-playwright/firefox-${FF_REV}/` (+ ICU/Juggler launch shim)
- WebKit → `/ms-playwright/webkit-${WK_REV}/` (`pw_run.sh` + minibrowser-{wpe,gtk};
  PW execs pw_run.sh directly, no shim). Producer ships the dist tree at `/webkit`.

Each rev is a hardcoded ARG (`CHS_REV`/`FF_REV`/`WK_REV`) Renovate bumps from the
`ghcr .../playwright-alpine-browsers:<prefix>-<rev>` tags (PW browsers.json revision).
`playwright.config.ts` runs one chromium+firefox+webkit matrix on every flavor
(the isAlpine split was collapsed once WK landed). PR #82 (2026-07-28).

**Two WebKit-on-musl gotchas (both required):**
1. **seccomp** — WPE's `bwrap` can't nest in a container's default seccomp/userns
   → bake `ENV WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` AND the consumer
   container must run `--security-opt seccomp=unconfined`. Confirmed GHA `container:`
   jobs DO honor `--security-opt` in `container.options`. [[project_webkit_smoke_sandbox_strip_layers]]
2. **PW host-req false-positive** — `browserType.launch` throws "Host system is
   missing dependencies: libGLESv2.so.2, libx264.so" on musl even though the libs
   are present + MiniBrowser is ldd-clean. PW reads the ubuntu24 nativeDeps list
   (forced by `PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24`) and mis-validates on
   musl. Fix: bake `ENV PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1`. Verified
   locally: `WK_FAIL` → `WK_OK` with the skip. chromium/firefox pass the check.

Chromium here is the headless-shell (conformance-grade via from-source, see
[[project_chs_from_source_promote]]). [[project_headed_mode_support]]

**Consumer ships WPE only, NOT gtk (PR #87, 2026-07-29).** The WebKit producer
artifact `/webkit` carries BOTH ports — `minibrowser-wpe` (252 MB compressed) +
`minibrowser-gtk` (167 MB). `pw_run.sh` selects by flag: `--headless` → wpe, else
gtk. PW always launches headless here, so gtk was ~167 MB / ~400 MB-on-disk of
never-execed dead weight (this is WHY the alpine combined image was BIGGER than
ubuntu/official — from-source browsers + fat apk deps, not the base). Fix: the
consumer `COPY`s only `/webkit/minibrowser-wpe` + `/webkit/pw_run.sh`, omitting
gtk. Design invariant: **do not "restore" the full `/webkit` COPY** — headed
WebKit is unsupported on musl ([[project_webkit_gtk_headed_recursion]]); the
producer keeps both ports for when headed lands, and the conformance runner
(`build-runner.sh`) still stages the full tree for its headed leg.
