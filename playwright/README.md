# playwright layer — `{ubuntu,alpine}-{dood,dind}-playwright`

Adds [Playwright](https://playwright.dev) + browsers on top of the [pnpm](../pnpm/README.md) layer.

## What it adds
- **Playwright** (pinned by `PLAYWRIGHT_VERSION`) installed globally.
  - **Ubuntu**: the bundled browsers via `playwright install --with-deps --only-shell`;
    `PLAYWRIGHT_BROWSERS_PATH` is set.
  - **Alpine**: **Chromium-only** via the system `chromium` package at `/usr/bin/chromium-browser`;
    the bundled-browser download is skipped (see
    [Why Alpine is Chromium-only](#why-alpine-is-chromium-only)).

## Why Alpine is Chromium-only

Playwright doesn't drive off-the-shelf browsers — it builds and pins **patched** ones:
[Firefox](https://github.com/microsoft/playwright/tree/main/browser_patches/firefox) carries the
*Juggler* automation protocol and [WebKit](https://github.com/microsoft/playwright/tree/main/browser_patches/webkit)
is a patched build. Those are compiled against **glibc** and there are **no musl/Alpine builds**, so they
can't load on Alpine — and `playwright install --with-deps` runs `apt`, which doesn't exist there either.

Chromium is the exception: Playwright drives it over the stock **CDP** protocol, so it can point at the
distro's musl-native `chromium` package (`apk add chromium`) via `executablePath` — no patched build
needed. Hence Alpine tops out at Chromium.

Track whether this ever changes:
- [Playwright system requirements](https://playwright.dev/docs/intro#system-requirements) — the official
  supported-OS list. Today it's Debian / Ubuntu only; Alpine appearing here would mean musl builds exist.
- [microsoft/playwright#1986](https://github.com/microsoft/playwright/issues/1986) — the canonical
  "Alpine Linux Support" thread. A maintainer confirms there are no plans, and points at the remote
  `mcr.microsoft.com/playwright` browser container (connect over WebSocket) as the only cross-distro path.

## What it implies
- Built for **both modes and both OSes**: `ubuntu-dood-playwright`, `alpine-dind-playwright`, etc.
- **Slim — no compiler.** Built on the slim [`pnpm`](../pnpm/README.md) layer. If your tests' deps
  compile native addons, use the **`…-playwright-gyp`** twin (the same layer built on
  [`pnpm-gyp`](../pnpm-gyp/README.md)); its tag carries a `-gyp` suffix.
- The **heaviest** layer (Ubuntu bundles browsers; Alpine pulls system Chromium + fonts).
- The version-pinned tag carries the Playwright minor (`…-pwX.Y`).
- This directory also holds the **Playwright test project** (`tests/`, `playwright.config.ts`) that CI
  runs against the built image. The config auto-detects the system Chromium at
  `/usr/bin/chromium-browser` (Alpine) and runs Chromium-only when present.

## Required `playwright.config.ts` for Alpine consumers

Playwright's `executablePath` (in `launch()` or project `launchOptions`) must point at the system
Chromium installed by `alpine-…-playwright` at `/usr/bin/chromium-browser`. Vanilla Playwright won't
discover it on its own — `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` is set in the image so no bundled
browser is fetched at `pnpm install` time, and Playwright doesn't probe `$PATH` for system browsers.

Required snippet (or equivalent) when you use `alpine-…-playwright`:

```ts
import { defineConfig, devices } from '@playwright/test';

// jclaveau/alpine-…-playwright: Playwright cannot ship its bundled glibc Chromium on musl,
// so the image provides system chromium at /usr/bin/chromium-browser. Point Playwright at it.
export default defineConfig({
  projects: [{
    name: 'chromium',
    use: { ...devices['Desktop Chrome'],
           launchOptions: { executablePath: '/usr/bin/chromium-browser' } },
  }],
});
```

Without this, the alpine image's vanilla-config consumer gets `Executable doesn't exist at
/home/runner/.cache/ms-playwright/chromium-…/headless_shell` because
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` was honored at install time. Ubuntu images don't need this
override — Playwright finds its bundled browsers via `PLAYWRIGHT_BROWSERS_PATH`.

(`test-playwright-vanilla-config` in `.github/workflows/test-and-publish.yml` asserts both halves:
the failure mode with a stock `npx playwright init` config, and a passing run with the snippet
above — so we'll know the day Playwright upstream changes its resolution semantics or starts
discovering `/usr/bin/chromium-browser` directly.)
