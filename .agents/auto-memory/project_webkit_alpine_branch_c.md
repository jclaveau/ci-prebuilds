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

Related: [[project-pw-version-aware-chs-rev-chain]] (parallel topology for
chromium), [[project-pw-upstream-juggler-handshake-hang]] (FF #60, the
template for Tier-3 land-disabled handling).
