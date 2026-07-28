---
name: project-webkit-alpine-branch-c
description: WebKit on Alpine — Branch C (WPE+GTK from upstream WebKit at PW's pinned SHA); design rationale, ports order, JIT toggle, Tier-1-only initial scope
metadata:
  type: project
---

WebKit-for-Alpine pipeline lives at `playwright/alpine-browsers/webkit/`,
modelled on `firefox/` but with a different source strategy.

- **Source**: upstream `WebKit/WebKit@<sha>` at the SHA PW publishes in
  `browser_patches/webkit/UPSTREAM_CONFIG.sh` (currently `d8fa5ad85d…`, past
  WebKitGTK 2.50.2 so the musl `execinfo.h` guard is already in-tree).
- **No aports patch graft**. aports ships `webkit2gtk-4.1`/`-6.0` at 2.48.1 (no
  `wpewebkit` package); patches target the older GTK-only branch and PW pins a
  2.50+ revision. We crib cmake flags statically (`USE_LIBBACKTRACE=OFF`,
  `ENABLE_SAMPLING_PROFILER=OFF`, `ENABLE_DEVELOPER_MODE=OFF`) into
  `webkit/cmake-flags.overlay`.
- **Two ports mandatory**. PW's `packages/playwright-core/src/server/registry/
  index.ts` ldd-validates BOTH `minibrowser-wpe/{bin,lib,sys/lib}` AND
  `minibrowser-gtk/{bin,lib,sys/lib}`. `pw_run.sh` dispatches `--headless`→WPE,
  headed→GTK. Missing either tree → `playwright install webkit` fails.
- **Build order: WPE first, GTK second**. WPE drops the full GTK4 widget
  toolkit so it compiles faster (~20–30% lighter than GTK). It's the musl
  canary: if WPE fails, we fail fast at hour ~3 instead of hour ~7. GTK
  reuses ~30-40% of JSC/WTF/WebCore objects via the shared sccache.
- **JIT default ON**, flippable to OFF via the `webkit_enable_jit` dispatch
  input. JSC+musl JIT has historical hazard (TCMalloc, signal handling, JIT
  page perms) — no 2025-2026 umbrella bug found, but the OFF flag is a
  documented escape hatch.
- **Default off**. `build-webkit` job triggers on `workflow_dispatch` with
  `build_webkit=true` or PR label `build-webkit`. No push, no schedule.
  Cold compile is multi-hour and we don't want it auto-triggering.
- **Initial PR scope: Tier-1 only**. ELF + ldd integrity for both MiniBrowser
  binaries. The `apply-and-build.sh` + `bundle-dist.sh` chain handles the
  self-contained-artifact assembly (mirror of firefox's bundle-dist with
  RPATH=`$ORIGIN/../lib` for the binary, `$ORIGIN` for peer .so files).
- **Follow-ups**: Tier-2 (PW SDK launch via `playwright.webkit.launch()`),
  Tier-2.5 (RemoteInspector RPC sanity, mirror of FF library-smoke),
  Tier-3 (upstream PW `tests/library/`, expect `if: false` à la FF #60 if
  RemoteInspector handshake hangs on musl). Consumer wiring
  (`playwright/Dockerfile.alpine` ARG, `on-demand-build.yml`,
  `test-and-publish.yml`, Renovate `WEBKIT_REV` customManager) lands after
  the first successful cold build publishes a `wk-<rev>` tag.
- **MERGED 2026-06-26** (PR #61, squash-merge commit
  `90102ce27b28bd66f6cba25b0573da4eb81a71f3` to `main`). Final state:
  - **Tier-2 headless WPE PW SDK ✅** — full launch + newContext + newPage
    + locator + route + screenshot, `targetDestroyed crashed:false`
  - **Tier-1 binary integrity ✅** for both ports
  - **Tier-2 headed GTK gated `if: false`** — GTK4-on-musl recursion;
    see [[webkit-gtk-headed-recursion]]; infra in tree, one flag-flip
    from re-enable
  - Root cause of WPE crash was `_FORTIFY_SOURCE` + Skia typed-pointer
    `__memcpy_chk` trap, fixed in `cmake-flags.overlay`; see
    [[webkit-fortify-source-skia-trap]] + cross-project
    [[feedback-fortify-typed-pointer-trap]]
  - Final verification run `28155403807` (~9h12min wall)
  - Standalone iter workflow `smoke-webkit-iter` shipped for future
    diagnosis cycles (~5min vs ~9h producer rebuild)

**Musl walls resolved during iters #11-#22** (BOTH ports unless noted):

- **`Page::setOverrideOrientation` undeclared** (both ports). PW's source
  patch adds an unguarded call in `WebPage.cpp`'s constructor; method body
  is gated by `ENABLE(ORIENTATION_EVENTS)`. PW's bootstrap.diff sets the
  default for neither port. Fix: `prep-source.sh` awk-inserts
  `WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_ORIENTATION_EVENTS PRIVATE ON)`
  into `OptionsWPE.cmake` AND `OptionsGTK.cmake` (inside `WEBKIT_OPTION_END()`
  guard — PRIVATE means `-D…=ON` from CLI is ignored).
- **`TextChecker::loadedSpellCheckingLanguages` not declared** (WPE port).
  Only declared under `#if PLATFORM(GTK)` in TextChecker.h. WPE port's
  `WebKitWebContext.cpp` call site gated by `ENABLE(SPELLCHECK)` only. Fix:
  do NOT pass `-DENABLE_SPELLCHECK=ON` (cmake-flags.overlay note).
- **`libintl_bindtextdomain` undefined at link** (both ports). musl puts
  gettext wrappers in `libintl.so` (`gettext-dev` apk pkg), unlike glibc
  where they're in `libc`. cmake's `find_package(Intl)` finds gettext but
  doesn't auto-link Intl on `libWPEWebKit`. Fix: `gettext-dev` apk +
  `CMAKE_C_STANDARD_LIBRARIES=-lintl` + `CMAKE_CXX_STANDARD_LIBRARIES=-lintl`
  in cmake-flags.overlay (CMake ≥3.13).
- **`tracePoint`/`RenderingUpdateRunLoopObserver*` undeclared in
  `DrawingAreaCoordinatedGraphicsGLib.cpp`** (GTK port). Source calls
  `tracePoint()`/`WTFEmitSignpost()` but never includes `<wtf/SystemTracing.h>`
  — upstream relies on transitive include via sibling .cpps in unified-source
  buckets. On Alpine/musl with clang's bucketing the chain breaks. Fix:
  `prep-source.sh` awk-injects explicit `#include <wtf/SystemTracing.h>`
  after `#include "WebProcess.h"` in that one file.
- **`USE(SYSPROF_CAPTURE)` is PRIVATE ON in OptionsGTK.cmake** (GTK port).
  Pulls `<wtf/glib/SysprofAnnotator.h>` which includes `sysprof-capture-types.h`.
  Fix: `sysprof-dev` apk pkg (provides system sysprof-capture headers).

**Iter speedup notes** (post-WPE-green):

- **Narrow `Dockerfile.source-prep` COPY surface** (iter #20, commit
  `048fd80`): only COPY `prep-source.sh` + `fetch-pw-patches.sh` (the two
  scripts source-prep actually runs), NOT all of `webkit/scripts/` or
  `cmake-flags.overlay`. Editing the latter no longer busts the source-prep
  layer. Iter #21 source-prep dropped to **50s** (registry cache hit).
- **prebuilt-base-wk-<sha> (TODO)**: bake `WebKitBuild/{WPE,GTK}/Release/`
  obj tree + sccache state into a published GHCR image. Future iters FROM
  that → re-link only, ~10m instead of ~9h. Roadmap step 2.

**WK conformance runner deps (2026-07-16):** `icu-data-full` (full CLDR)
RECOVERS the 4 locale format tests — JSC's Intl uses SYSTEM ICU (unlike FF's
SpiderMonkey which bundles its own in libxul, so icu-data-full does NOT help
FF locale). But `gst-plugins-ugly` + `openh264` in the runner apks did NOT
enable WK's GStreamer decode of the 4 play-video/webm/audio/mp4 tests — WK's
media pipeline needs a WebKit BUILD FLAG / WPE MediaStream backend, not runner
apks. Codec stays structural. Runner also needs `nss` apk for the recorder-UI
chromium bundle's NSS module search-path. WK ended 89.8% of Ubuntu, zero
Alpine-only fails.

Related: [[project-pw-version-aware-chs-rev-chain]] (parallel topology for
chromium), [[project-pw-upstream-juggler-handshake-hang]] (FF #60, the
template for Tier-3 land-disabled handling), [[recorder-family-chromium-bundle]],
[[pw-conformance-scope-out-of-scope]].
