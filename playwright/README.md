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

**Ubuntu vs Alpine**:

- **Pick Ubuntu** for the full three-engine matrix (Chromium + Firefox + WebKit,
  Playwright-bundled browsers).
- **Pick Alpine** for a smaller image — now ships the **full three-engine matrix
  too**, all musl-native (**chromium-headless-shell + Firefox + WebKit-WPE**) via
  the [`playwright-alpine-browsers`](https://github.com/jclaveau/ci-prebuilds/tree/main/playwright/alpine-browsers)
  producer image.
- WebKit on Alpine needs `--security-opt seccomp=unconfined` on the container
  (its `bwrap` sandbox; see [WebKit note](#webkit-on-alpine-needs-seccompunconfined)).
  Chromium + Firefox need nothing extra.

## What it adds
- **Playwright** (pinned by `PLAYWRIGHT_VERSION`) installed globally.
  - **Ubuntu**: the bundled browsers via `playwright install --with-deps --only-shell`;
    `PLAYWRIGHT_BROWSERS_PATH` is set.
  - **Alpine**: musl-native **chromium-headless-shell + Firefox + WebKit-WPE**
    staged at PW SDK's auto-discovery cache path. Bundled-browser download is
    skipped (see [musl-native browsers on Alpine](#musl-native-browsers-on-alpine)).

## musl-native browsers on Alpine

Playwright doesn't drive off-the-shelf browsers — it builds and pins **patched** ones:

- [Firefox](https://github.com/microsoft/playwright/tree/main/browser_patches/firefox) carries
  the *Juggler* automation protocol.
- [WebKit](https://github.com/microsoft/playwright/tree/main/browser_patches/webkit) is a
  patched build.
- `chromium-headless-shell` is a deterministic headless variant Google ships via
  Chrome-for-Testing.

Upstream PW publishes those compiled against **glibc** only — no musl artifacts.

The `playwright-alpine-browsers` sub-project produces musl-native equivalents:

- **chromium-headless-shell**: extracted from Alpine community's
  `chromium-headless-shell` apk subpackage (aports already builds it for
  musl as part of `community/chromium`). Bundled `.so` deps + `RPATH=$ORIGIN`
  so the artifact is self-contained.
- **Firefox**: built from PW's pinned Mozilla source with PW's `bootstrap.diff` +
  `juggler/` overlay, on top of Alpine `aports/community/firefox`'s musl
  patches. Staged here as `ff-{revision}`. A launch shim points `ICU_DATA` at
  the bundled data file and forces Juggler activation via
  `--remote-debugging-port=0`.
- **WebKit**: WPE (headless) + GTK (headed) `MiniBrowser` built from upstream
  WebKit at PW's pinned SHA. Staged here as `wk-{revision}`; PW's `pw_run.sh`
  drives it directly (no shim). Needs `WEBKIT_DISABLE_SANDBOX` (baked in the
  image) **and** `--security-opt seccomp=unconfined` on the container.

The producer publishes versioned + moving tags on both GHCR (CI-friendly,
no Docker Hub pull-limit) and Docker Hub (external catalog):

```
ghcr.io/jclaveau/playwright-alpine-browsers:chs-{revision}   jclaveau/...:chs-{revision}
ghcr.io/jclaveau/playwright-alpine-browsers:chs-latest       jclaveau/...:chs-latest
ghcr.io/jclaveau/playwright-alpine-browsers:ff-{revision}    jclaveau/...:ff-{revision}
ghcr.io/jclaveau/playwright-alpine-browsers:wk-{revision}    jclaveau/...:wk-{revision}
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
- Inherits the [pnpm `install -g` under `act --bind` limit](../pnpm/README.md#known-limit-pnpm-install--g-under-act---bind---user-non-1001).
  Acute here: any `pnpm add -g <pkg>` during the job re-`chmod`s the pre-baked `playwright` bin → EPERM.
- The **heaviest** layer (browsers + runtime deps); Alpine now switches from
  the full Alpine Chromium apk to musl-native `chromium-headless-shell`
  (deterministic timing for tests).
- The version-pinned tag carries the Playwright minor (`…-pwX.Y`).
- This directory also holds the **Playwright test project** (`tests/`,
  `playwright.config.ts`) that CI runs against the built image. The config
  runs the same three-browser matrix (chromium + firefox + webkit) on every
  flavor.

## Required `playwright.config.ts` for Alpine consumers

**Nothing required.** PW SDK auto-discovers all three staged browsers via
`PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` set in the image. Your own
`playwright.config.ts` can use vanilla project definitions for chromium,
firefox and webkit; no `executablePath` override needed.

### WebKit on Alpine needs `seccomp=unconfined`

WebKit-WPE's `bwrap` sandbox can't nest inside a container's default
seccomp/user-ns profile on musl. The image bakes
`WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`, but the container must **also**
run with `--security-opt seccomp=unconfined`:

```yaml
container:
  image: jclaveau/alpine-dood-playwright:latest
  options: --security-opt seccomp=unconfined
```

Chromium and Firefox need nothing extra. Omit webkit from your `--project`
set if you don't want to loosen seccomp.
