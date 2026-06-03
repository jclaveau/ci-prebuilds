# playwright layer — `{ubuntu,alpine}-{dood,dind}-playwright`

Adds [Playwright](https://playwright.dev) + browsers on top of the [pnpm](../pnpm/README.md) layer.

## Usage

Published as `jclaveau/<os>-<mode>-playwright` on Docker Hub — four variants
(`ubuntu-dood-playwright`, `ubuntu-dind-playwright`, `alpine-dood-playwright`,
`alpine-dind-playwright`), plus the `-gyp` twin for each. Tags: `:latest` and version-pinned
`:<os>-<node-minor>-<pnpm-minor>-pw<pw-minor>`, e.g.
`jclaveau/ubuntu-dood-playwright:ubuntu24.04-node22.12-pnpm9.15-pw1.50`. Append `-sudoer` to the
image name for the non-hardened flavor; append `-gyp` (image AND tag) for native-addon builds.

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest
    container: jclaveau/ubuntu-dood-playwright:latest
    steps:
      - uses: actions/checkout@v4
      - run: pnpm install --frozen-lockfile
      - run: pnpm exec playwright test
```

**Ubuntu vs Alpine**: pick **Ubuntu** for the full three-engine matrix
(Chromium + Firefox + WebKit, Playwright-bundled browsers). Pick **Alpine**
for a smaller image — Alpine now ships **musl-native Chromium + Firefox**
via the [`playwright-alpine-browsers`](https://github.com/jclaveau/github-action-container-images/tree/main/playwright/alpine-browsers)
producer image. WebKit on Alpine is still deferred (no PW-patched musl
WebKit build exists yet); the alpine `playwright.config.ts` skips it
automatically so `playwright test` (no `--project`) stays green.

## What it adds
- **Playwright** (pinned by `PLAYWRIGHT_VERSION`) installed globally.
  - **Ubuntu**: the bundled browsers via `playwright install --with-deps --only-shell`;
    `PLAYWRIGHT_BROWSERS_PATH` is set.
  - **Alpine**: musl-native **chromium-headless-shell** + **Firefox** staged
    at PW SDK's auto-discovery cache path. Bundled-browser download is
    skipped (see [musl-native browsers on Alpine](#musl-native-browsers-on-alpine)).

## musl-native browsers on Alpine

Playwright doesn't drive off-the-shelf browsers — it builds and pins
**patched** ones. [Firefox](https://github.com/microsoft/playwright/tree/main/browser_patches/firefox)
carries the *Juggler* automation protocol, [WebKit](https://github.com/microsoft/playwright/tree/main/browser_patches/webkit)
is a patched build, and `chromium-headless-shell` is a deterministic
headless variant Google ships via Chrome-for-Testing. Upstream PW publishes
those compiled against **glibc** only — no musl artifacts.

The `playwright-alpine-browsers` sub-project produces musl-native equivalents:

- **Firefox**: built from PW's pinned Mozilla source with PW's `bootstrap.diff` +
  `juggler/` overlay, on top of Alpine `aports/community/firefox`'s musl
  patches. Same revision + browserVersion as `pnpm playwright install` would
  have downloaded; mimicked exactly so PW SDK's auto-discovery picks it up
  without an `executablePath` override.
- **chromium-headless-shell**: extracted from Alpine community's
  `chromium-headless-shell` apk subpackage (aports already builds it for
  musl as part of `community/chromium`). Bundled `.so` deps + `RPATH=$ORIGIN`
  so the artifact is self-contained.
- **WebKit**: not yet shipped — sub-project deferred. Drop in when ready.

The producer publishes versioned + moving tags on both GHCR (CI-friendly,
no Docker Hub pull-limit) and Docker Hub (external catalog):

```
ghcr.io/jclaveau/playwright-alpine-browsers:ff-{revision}    jclaveau/...:ff-{revision}
ghcr.io/jclaveau/playwright-alpine-browsers:ff-latest        jclaveau/...:ff-latest
ghcr.io/jclaveau/playwright-alpine-browsers:chs-{revision}   jclaveau/...:chs-{revision}
ghcr.io/jclaveau/playwright-alpine-browsers:chs-latest       jclaveau/...:chs-latest
```

Renovate keeps the COPY --from tags in `Dockerfile.alpine` synced with
`playwright@${PLAYWRIGHT_VERSION}`'s pinned revisions.

Useful upstream references:
- [Playwright system requirements](https://playwright.dev/docs/intro#system-requirements) —
  the official supported-OS list. Today Alpine doesn't appear there; this
  image is the wedge that fills the gap.
- [microsoft/playwright#1986](https://github.com/microsoft/playwright/issues/1986) —
  canonical "Alpine Linux Support" thread; PW maintainers state no plans for
  official musl builds.

## What it implies
- Built for **both modes and both OSes**: `ubuntu-dood-playwright`, `alpine-dind-playwright`, etc.
- **Slim — no compiler.** Built on the slim [`pnpm`](../pnpm/README.md) layer. If your tests' deps
  compile native addons, use the **`…-playwright-gyp`** twin (the same layer built on
  [`pnpm-gyp`](../pnpm-gyp/README.md)); its tag carries a `-gyp` suffix.
- The **heaviest** layer (browsers + runtime deps); Alpine grows vs the
  previous Chromium-only build but gains a second working engine.
- The version-pinned tag carries the Playwright minor (`…-pwX.Y`).
- This directory also holds the **Playwright test project** (`tests/`,
  `playwright.config.ts`) that CI runs against the built image. The config
  detects Alpine via `/etc/alpine-release` and runs `chromium + firefox`
  there; other OSes run the full three-browser matrix.

## Required `playwright.config.ts` for Alpine consumers

**Nothing required.** PW SDK auto-discovers the staged browsers via
`PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` set in the image. Your own
`playwright.config.ts` can use vanilla project definitions; no
`executablePath` override needed. Just be aware: WebKit isn't shipped on
Alpine yet — either omit the WebKit project (we do this in the in-repo
`playwright.config.ts`) or pass `--project=chromium,firefox` to filter at
test invocation time.

For Firefox specifically, the alpine image includes a 4-line shim that
prepends `--remote-debugging-port=0` to every `firefox.launch()` — works
around a Juggler-activation quirk in our musl FF build (not musl-specific;
same dormant behavior on glibc when building from PW's patches outside
their CDN pipeline). Transparent to your tests.
