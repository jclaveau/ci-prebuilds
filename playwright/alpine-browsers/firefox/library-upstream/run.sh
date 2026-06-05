#!/bin/sh
# Phase B — run microsoft/playwright's own tests/library suite against our
# musl-built Firefox artifact. Authoritative signal: same tests PW maintainers
# use to certify a FF build "PW-compatible."
#
# Inputs (env):
#   PW_VERSION  — exact PW pin to check out (must match the FF artifact's
#                 browsers.json revision; producer build resolves this).
#   FFPATH      — absolute path to our firefox binary inside the runner.
#
# What runs: a curated subset of tests/library/ specs that exercise the
# Juggler protocol surfaces with the highest regression-catch value per
# minute. NOT the full suite — that would take hours and includes browser-
# version-coupled assertions that flake on PW-patched builds.
#
# Why a subset (not the full firefox-library project):
#   - Full project is ~400 specs, ~45min on hosted runners.
#   - Many specs assume Mozilla release-channel build details (about: pages,
#     prefs, default UI) that PW's patched build can diverge on.
#   - Our use case is "drive FF via PW SDK on alpine/musl"; we want to catch
#     protocol-level regressions in the surfaces consumers actually call.
#
# Curated specs (each ~20-40 tests, all baseline behavior):
#   browsertype-basic     — launch / launchPersistent / connect / executablePath
#   browser.spec          — newContext, newBrowserCDPSession, close, version
#   browsercontext-basic  — addCookies / cookies / clearCookies, route, request
#   browsercontext-cookies — full cookie matrix (domain, path, expiry, sameSite)
#
# Expand the list (or drop --project= filter) when we want broader coverage.

set -eu

: "${PW_VERSION:?PW_VERSION must be set}"
: "${FFPATH:?FFPATH must be set}"

[ -x "$FFPATH" ] || { echo "FFPATH does not point to an executable: $FFPATH" >&2; exit 1; }

PW_TAG="v${PW_VERSION}"
PW_SRC="${PW_SRC:-/pw-src}"

echo "==== Cloning microsoft/playwright@${PW_TAG} ===="
mkdir -p "$PW_SRC"
git clone --depth 1 --branch "$PW_TAG" \
  https://github.com/microsoft/playwright.git "$PW_SRC"

cd "$PW_SRC"

echo "==== npm ci (cold install, ~3-5min) ===="
# --no-audit / --no-fund / --prefer-offline shave ~30s off cold installs.
# PW's package-lock.json pins exact versions; npm ci is reproducible.
npm ci --no-audit --no-fund --prefer-offline

echo "==== npm run build (TypeScript → JS via esbuild) ===="
npm run build

echo "==== Running curated firefox-library subset ===="
# PWTEST_UNDER_TEST=1 is set by tests/library/playwright.config.ts; we just
# need to set FFPATH so its getExecutablePath() returns our binary.
# --reporter=dot keeps stdout terse but visible per-test.
# --workers=1 because the artifact's renderer-sandbox needs --security-opt
# seccomp=unconfined (already passed by the caller); parallel browser
# launches on hosted runners often OOM the 7GB ubuntu-latest box anyway.
export PWTEST_UNDER_TEST=1

exec npx playwright test \
  --config=tests/library/playwright.config.ts \
  --project=firefox-library \
  --reporter=dot \
  --workers=1 \
  tests/library/browsertype-basic.spec.ts \
  tests/library/browser.spec.ts \
  tests/library/browsercontext-basic.spec.ts \
  tests/library/browsercontext-cookies.spec.ts
