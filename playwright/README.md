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
for a smaller image — Alpine ships **musl-native chromium-headless-shell**
via the [`playwright-alpine-browsers`](https://github.com/jclaveau/github-action-container-images/tree/main/playwright/alpine-browsers)
producer image. Firefox and WebKit on Alpine are deferred (see below); the
alpine `playwright.config.ts` skips them automatically so `playwright test`
(no `--project`) stays green.

## What it adds
- **Playwright** (pinned by `PLAYWRIGHT_VERSION`) installed globally.
  - **Ubuntu**: the bundled browsers via `playwright install --with-deps --only-shell`;
    `PLAYWRIGHT_BROWSERS_PATH` is set.
  - **Alpine**: musl-native **chromium-headless-shell** staged at PW SDK's
    auto-discovery cache path. Bundled-browser download is skipped (see
    [musl-native browsers on Alpine](#musl-native-browsers-on-alpine)).

## musl-native browsers on Alpine

Playwright doesn't drive off-the-shelf browsers — it builds and pins
**patched** ones. [Firefox](https://github.com/microsoft/playwright/tree/main/browser_patches/firefox)
carries the *Juggler* automation protocol, [WebKit](https://github.com/microsoft/playwright/tree/main/browser_patches/webkit)
is a patched build, and `chromium-headless-shell` is a deterministic
headless variant Google ships via Chrome-for-Testing. Upstream PW publishes
those compiled against **glibc** only — no musl artifacts.

The `playwright-alpine-browsers` sub-project produces musl-native equivalents:

- **chromium-headless-shell**: extracted from Alpine community's
  `chromium-headless-shell` apk subpackage (aports already builds it for
  musl as part of `community/chromium`). Bundled `.so` deps + `RPATH=$ORIGIN`
  so the artifact is self-contained.
- **Firefox**: built from PW's pinned Mozilla source with PW's `bootstrap.diff` +
  `juggler/` overlay, on top of Alpine `aports/community/firefox`'s musl
  patches. Producer publishes `ff-{revision}` but consumer wiring isn't
  shipped here yet — cross-musl-version ABI mismatch (producer built on
  alpine edge, this consumer base is 3.21) causes a segfault at XPCOM init.
  Follow-up.
- **WebKit**: not yet shipped — sub-project deferred. Drop in when ready.

The producer publishes versioned + moving tags on both GHCR (CI-friendly,
no Docker Hub pull-limit) and Docker Hub (external catalog):

```
ghcr.io/jclaveau/playwright-alpine-browsers:chs-{revision}   jclaveau/...:chs-{revision}
ghcr.io/jclaveau/playwright-alpine-browsers:chs-latest       jclaveau/...:chs-latest
ghcr.io/jclaveau/playwright-alpine-browsers:ff-{revision}    jclaveau/...:ff-{revision}      (published, not wired here yet)
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
- The **heaviest** layer (browsers + runtime deps); Alpine now switches from
  the full Alpine Chromium apk to musl-native `chromium-headless-shell`
  (deterministic timing for tests).
- The version-pinned tag carries the Playwright minor (`…-pwX.Y`).
- This directory also holds the **Playwright test project** (`tests/`,
  `playwright.config.ts`) that CI runs against the built image. The config
  detects Alpine via `/etc/alpine-release` and runs `chromium` only there;
  other OSes run the full three-browser matrix.

## Required `playwright.config.ts` for Alpine consumers

**Nothing required.** PW SDK auto-discovers the staged browser via
`PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` set in the image. Your own
`playwright.config.ts` can use vanilla project definitions; no
`executablePath` override needed. Just be aware: Firefox and WebKit aren't
shipped on Alpine yet — either omit those projects (we do this in the
in-repo `playwright.config.ts`) or pass `--project=chromium` to filter at
test invocation time.
