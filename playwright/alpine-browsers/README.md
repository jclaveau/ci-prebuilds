# `playwright/alpine-browsers/`

Build-only sub-project that produces Playwright-patched browser binaries for
musl/Alpine, published as the artifact image `jclaveau/playwright-alpine-browsers`.

Today: **Firefox** (mature), **chromium-headless-shell** (apk fast path), and
**WebKit** (initial Branch-C cold build — default off).

WebKit is the newest addition. PW ships its WebKit as BOTH `minibrowser-wpe/`
and `minibrowser-gtk/` (`pw_run.sh` dispatches `--headless`→WPE, headed→GTK)
and ldd-validates both at install time. There is no aports `wpewebkit` package,
so we build WPE+GTK from upstream WebKit at PW's pinned SHA in a single job —
WPE first as the shorter port and musl canary, GTK second with a warm sccache.
Default off (the cold build is multi-hour); see `webkit/` and the producer
workflow's `build-webkit` job.

## Why this is a separate image

Playwright's bundled Firefox is glibc-only. The Alpine `playwright-alpine`
runner image (in the parent directory) cannot run it. This sub-project rebuilds
Playwright-patched Firefox against musl so the runner can `COPY --from=` the
binary and point `PLAYWRIGHT_FIREFOX_EXECUTABLE_PATH` at it.

The build is heavy (~1.5–2.5h on hosted runners) and only needs to rerun when
Playwright rolls its `browser_patches/firefox/` upstream — observed cadence
~every 6–8 weeks (~7–8× per year). So this lives in its own producer workflow
(`.github/workflows/playwright-alpine-browsers.yml`), separate from the main
`test-and-publish.yml`. The runner image consumes the published artifact tag.

## How it works

The recipe grafts two patch sets onto Mozilla's stock Firefox source:

1. **Alpine's musl patches** (libc-layer): from
   `gitlab.alpinelinux.org/alpine/aports community/firefox/*.patch`. These make
   Firefox build and run on musl.
2. **Playwright's `bootstrap.diff` + Juggler tree** (engine-layer): from
   `microsoft/playwright browser_patches/firefox/`. Adds the Juggler automation
   protocol that Playwright drives Firefox through.

The two sets target different layers of the source tree (libc internals vs
browser engine), so they don't overlap in practice. If they ever do, the build
fails loudly at `patch -p1` and the conflict is the reconciliation point.

The Firefox source itself comes from Mozilla's release tarball at the version
aports' APKBUILD pins (`pkgver`). The build asserts at runtime that this
version's major.minor matches the Firefox version Playwright pins (read from
`browsers.json` in `playwright-core@${PW_VERSION}`); a mismatch is a build
failure.

## Pin tracking

Renovate manages `versions.env`:

- `PW_VERSION` → tracked as the `playwright` npm package, via a custom regex
  manager in `renovate.json`. When PW publishes a new version, Renovate opens a
  PR bumping the pin. The patch fetcher reads PW's `browsers.json` at this
  version to discover the firefox revision + version pinned.
- `ALPINE_APORTS_REF` → defaults to `master` (aports is rolling). aports keeps
  its firefox recipe aligned with Mozilla's releases. If we ever need
  reproducibility we can pin to a commit and add a `git-refs` Renovate manager.

A weekly cron is intentionally absent — Renovate is the drift detector. Manual
rebuilds use `workflow_dispatch` on the producer workflow.

## WebKit (Branch C — initial cold-build, dispatch-gated)

PW's WebKit Linux artifact ships BOTH `minibrowser-wpe/` and `minibrowser-gtk/`
under one revision. We mirror that layout by building both ports against the
same WebKit upstream checkout at PW's pinned SHA.

- Source: `WebKit/WebKit@<sha>` from `browser_patches/webkit/UPSTREAM_CONFIG.sh`.
  PW's pinned revision is past WebKitGTK 2.50.2 (which guards the upstream
  `execinfo.h` include for musl), so the well-known musl wall on the 2.48
  branch is already fixed in our checkout.
- Patches: PW's `browser_patches/webkit/patches/` + `embedder/` overrides.
  We don't graft aports' patches — they target the older 2.48 GTK-only branch.
- cmake flags: cribbed statically from aports `community/webkit2gtk-6.0`
  APKBUILD into `webkit/cmake-flags.overlay`. Notable: `USE_LIBBACKTRACE=OFF`
  (silences the WTF stacktrace path that pulls glibc-leaning libbacktrace) and
  `ENABLE_JIT=ON` by default (flippable to `OFF` via dispatch input if JSC+musl
  JIT blocks — historical hazard not blocking us today, but worth keeping
  reachable).
- Build order: WPE first (shorter port = musl canary), GTK second. sccache is
  shared across both ports — second build reuses ~30-40% of JSC/WTF/WebCore
  objects.
- Default off. Cold compile is multi-hour; we don't want push events to trigger
  it. Trigger via `workflow_dispatch` with `build_webkit=true` or PR label
  `build-webkit`. promote runs on dispatch with `build_webkit=true` or on main
  pushes.
- Initial PR ships Tier-1 only (ELF + ldd integrity for both MiniBrowser
  binaries). Tier-2 (PW SDK launch), Tier-2.5 (RemoteInspector RPC sanity),
  and Tier-3 (upstream PW `tests/library/`) follow once cold-build is
  reproducible. Tier-3 will likely land `if: false` à la Firefox #60 if the
  RemoteInspector handshake hangs on musl.

Open risks (in order of likelihood): JSC+musl JIT, RemoteInspector handshake
on musl, ~5–8h cold-build wall on hosted runners. Mitigations in plan +
`webkit/scripts/apply-and-build.sh` comments.

## How to add another browser later

The sub-project layout is browser-agnostic. To add a fourth browser, follow
the firefox/ or webkit/ shape: a per-browser subdir with build scripts +
config overlay, a per-browser producer Dockerfile, and producer workflow jobs
named `build-<browser>` + `promote-<browser>`.

## Local dev

```bash
cd playwright/alpine-browsers
docker build --target=artifact -t playwright-alpine-browsers:dev .
# Smoke test (Tier 1):
docker run --rm --entrypoint /firefox/firefox playwright-alpine-browsers:dev --version
```

For full validation against a `playwright-alpine` candidate image, see the
producer workflow's `smoke` job.

## Files

- `Dockerfile` — multi-stage Firefox builder → scratch artifact
- `Dockerfile.iter`, `Dockerfile.prebuilt-base`, `Dockerfile.glibc-debug` —
  Firefox iteration paths
- `versions.env` — `PW_VERSION`, `ALPINE_APORTS_REF`, `PW_FIREFOX_SHA`,
  `PW_WEBKIT_SHA`, plus chromium aports ref
- `firefox/{mozconfig.overlay,scripts/*,smoke/,library-smoke/,library-upstream/}`
- `chromium-headless-shell/{Dockerfile.apk,Dockerfile,smoke/,scripts/}`
- `webkit/`
  - `Dockerfile` — alpine:edge → apk build deps → fetch PW patches → cmake/ninja
    WPE then GTK → scratch artifact
  - `cmake-flags.overlay` — cribbed cmake args (sourced by apply-and-build.sh)
  - `scripts/fetch-pw-patches.sh` — pulls PW's `browser_patches/webkit/`
  - `scripts/apply-and-build.sh` — clones WebKit at PW SHA, applies patches,
    configures + ninjas both ports, stages `/work/webkit-dist/`
  - `scripts/bundle-dist.sh` — ldd-walk + RPATH=$ORIGIN per port (mirrors
    firefox/scripts/bundle-dist.sh)
