---
name: project_wk_mimalloc_past_bmalloc
description: WebKit's startup cluster was musl mallocng, not bmalloc — preloading mimalloc via pw_run.sh takes context_page 1.30→0.95, goto_cold 1.52→1.12, click_force 1.37→1.20; launch is unmoved and goto_warm regresses
metadata:
  type: project
---

`bmalloc`/`libpas` IS compiled into our WebKit (upstream sets
`USE_SYSTEM_MALLOC_DEFAULT OFF` for `WTF_CPU_X86_64` with **no libc
condition** — the musl-forces-system-malloc folklore is not in this tree), so
the allocator looked closed. It was not: **bmalloc backs `WTF::fastMalloc`
only** — WebCore and JSC. GLib, GObject, GStreamer, Skia, Cairo, HarfBuzz, ICU,
libsoup, fontconfig and freetype all go to musl's mallocng.

That split is visible in the metrics before you touch anything: startup and
page setup red (goto_cold 1.52, launch 1.37, click_force 1.30, context_page
1.26) while engine code — the part bmalloc already covers — is *faster* than
official (layout 0.95, int_math 0.97, dom_churn 0.97).

Fix (PR #123): wrap `pw_run.sh` with `LD_PRELOAD=libmimalloc-insecure.so.2`
in `playwright/Dockerfile.alpine` **and** in the conformance runner
(`conformance/build-runner.sh`) so tested == shipped. Wrap rather than `sed`
its text: `pw_run.sh` is PW's file, and `Dockerfile.finalize` already seds one
line of it. It resolves everything from `$(dirname "$0")` so renaming it to
`pw_run.real.sh` beside itself is invisible to it.

Measured, runs=5, three same-CPU pairings:

```
metric          control      arm
context_page    1.24-1.31    0.94-0.96   <- below official
goto_cold       1.46-1.58    1.09-1.15
click_force     1.33-1.42    1.19-1.20
screenshot      1.04-1.08    1.01-1.04
launch          1.29-1.37    1.31-1.35   <- UNMOVED
goto_warm       1.17-1.20    1.23-1.39   <- REGRESSED, unexplained
layout/int_math/dom_churn/libm_fmod      flat (the control)
```

**Two dead ends recorded so nobody re-spends them.** Firefox's `nm -D`
discriminator does NOT transfer: `malloc` is undefined in ours *and* in
official's `libWPEWebKit`, because bmalloc never interposes global `malloc` —
use the `pas_`/`bmalloc` string counts instead. And `launch` is NOT the DSO
closure that explains chromium's ([[project_chromium_launch_dso_closure]]):
ours carries **60** `DT_NEEDED` against official's **70**, their MiniBrowser
74 — our closure is the leaner one.

Verify the lever the same way every time: launch, then read `/proc/*/maps` for
`mimalloc` — it must be true for MiniBrowser + WPEWebProcess +
WPENetworkProcess and **false for the node driver**, with the un-wrapped image
as a negative control. [[project_ff_build_missing_pgo_lto_jemalloc]]
