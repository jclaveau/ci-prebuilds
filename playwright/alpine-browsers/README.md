# `playwright/alpine-browsers/`

Build-only sub-project that produces Playwright-patched browser binaries for
musl/Alpine, published as the artifact image `jclaveau/playwright-alpine-browsers`.

Today: **Firefox only**. WebKit is deferred — Playwright's WebKit is the
WPE/GTK MiniBrowser with a custom remote-inspector socket, and there is no
equivalent musl recipe to graft against (aports' `webkit2gtk-*` is vanilla,
no Juggler-equivalent patches).

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

## How to add another browser later

The sub-project layout is intentionally browser-agnostic. To add (say) WebKit:

1. Add `webkit/` sibling to `firefox/` with the same shape:
   `webkit/{mozconfig.overlay-or-equivalent, scripts/{fetch-*, apply-and-build.sh}}`.
2. Add a new `RUN` step in the `Dockerfile` for the webkit-builder stage.
3. Add a new `COPY --from=webkit-stage /artifact/webkit /webkit` at the bottom.
4. Extend the producer workflow's Tier-2 smoke test to also run a webkit
   project subset.

The consumer `playwright/Dockerfile.alpine` then `COPY --from`s `/webkit` and
sets `PLAYWRIGHT_WEBKIT_EXECUTABLE_PATH`.

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

- `Dockerfile` — multi-stage builder → scratch artifact
- `versions.env` — `PW_VERSION`, `ALPINE_APORTS_REF`, plus informational pins
- `firefox/mozconfig.overlay` — turns off PGO and other distro-only options
- `firefox/scripts/fetch-aports.sh` — pulls aports community/firefox files
- `firefox/scripts/fetch-pw-patches.sh` — pulls PW's bootstrap.diff + Juggler
- `firefox/scripts/apply-and-build.sh` — orchestrates patch + `./mach build`
