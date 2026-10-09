---
name: project_wk_pgo_multidso_sigbus_percent_m
description: WebKit PGO Phase 0 instrumented smoke SIGBUS'd because ~12 instrumented .so's share one LLVM_PROFILE_FILE name under -fprofile-continuous; fix is adding %m to the pattern; CONFIRMED in the real rerun 2026-09-24 (SIGBUS gone), but every profraw now truncates behind a MESA ZINK vkCreateInstance VK_ERROR_INCOMPATIBLE_DRIVER — undiagnosed
metadata:
  type: project
---

WK PGO candidate A (run 35999751957, `perf/wk-pgo`) died 2h57 into Phase 0's
instrumented smoke: `MiniBrowser --headless about:blank` → `Bus error (core
dumped)`, profraw truncated, `llvm-profdata merge` → "no profile can be
merged".

Root cause: WebKit's build instruments ~12 shared libraries, and each one
links its own compiler-rt profile runtime. With `LLVM_PROFILE_FILE` set to
`wk-%p-%c` (no `%m`), every DSO's runtime resolves to the *same* filename.
Each one `ftruncate`s it to its own counter-table size and `mmap`s it,
unmapping pages an earlier DSO's runtime was still writing through — next
increment hits unmapped memory → SIGBUS. Reproduced locally on Alpine clang
23.1.2 with 3 DSOs: `wk-%p-%c` → rc 135 (Bus error), 1 file, 1 function;
`wk-%p-%m-%c` → rc 0, 4 files, 1204 functions.

`%c` has to stay — it's what enables continuous mode at all. Verified
separately: the same binary built `-fprofile-continuous` but run without `%c`
in the filename leaves **zero** profraw on SIGTERM. With both `%m` and `%c`,
a SIGTERM at 3s (the corpus run's own shutdown signal) keeps 3 files / 803
functions with real counts.

Fix is a one-token change: `LLVM_PROFILE_FILE=wk-%p-%c` → `wk-%p-%m-%c`.
Shipped in `1b1354d` on `perf/wk-pgo` (2026-09-24), redispatched as run
36024117406.

**Why:** `%p` (pid) is shared across all DSOs in one process — it does not
disambiguate them. `%m` (module/binary build-id) is the only token in
compiler-rt's `LLVM_PROFILE_FILE` pattern language that varies per linked
image, so it's mandatory the moment more than one profiled binary can be
live in the same process. Single-binary instrumentation (most PGO setups)
never hits this; multi-DSO instrumentation of a browser engine (WebKit here,
likely any Chromium/Firefox component-build PGO too) always will.

**How to apply:** any future `-fprofile-continuous`/`-fprofile-instr-generate`
setup on a multi-`.so` target must use `%m` in `LLVM_PROFILE_FILE`, not just
`%p`. If a PGO Phase 0 SIGBUSes during the instrumented smoke with a truncated
profraw and "no profile can be merged", check this first before suspecting
the browser or the sandbox. Candidate B (`perf/wk-pgo-corpus` @ `d269561`,
paused per jean's "don't dispatch for now") branched off the pre-fix
`fe028ac` and carries the same bug — needs a rebase onto `1b1354d` before it
can ever run.

**2026-09-24, later: `%m` CONFIRMED in the real run — SIGBUS is gone, a
DIFFERENT failure took its place.** Redispatch `36024117406` reached the same
2h56-2h57 smoke-run point the dead run died at, but this time: instrumented
ninja `rc=0` at 2h47 (build itself is clean), and the smoke run produced **7
profraw files across 3 pids × 4 distinct image hashes** instead of the old
run's 1 file + `Bus error`. The multi-DSO filename collision is fixed — the
diagnosis held. But every one of the 7 files is now `truncated profile data`,
so `llvm-profdata merge` still fails with "no profile can be merged", just
via a different mechanism. The smoke log shows, before the profraw errors:
```
MESA: error: ZINK: vkCreateInstance failed (VK_ERROR_INCOMPATIBLE_DRIVER)
```
Not yet diagnosed — session ended mid-investigation, right after pulling
this log line and before reading the surrounding context. Open questions for
whoever picks this up: is Zink/Vulkan a red herring (WebKit's Skia backend
falls back to something else and this is normal warm-up noise on this
runner), or is `MiniBrowser --headless` now crash-looping/exiting early
mid-page-load in a way that leaves every DSO's profile counters mid-write —
which would explain "truncated" landing on ALL 7 files at once rather than
one. Check whether the smoke run's exit code was 0 or a crash before
re-diagnosing from scratch.

**2026-09-24, later still: the next redispatch (19:28:42Z, run
36048405627) never actually tested this fix.** It omitted `-f
webkit_pgo=on`, which defaults to `off` on `perf/wk-pgo`, so the run built
plain non-instrumented WPE for 2h56 with zero PGO signal — no Phase 0, no
Zink question answered either way. See
[[project_wk_pgo_dud_dispatch_missing_flag]]. Both the `%m` fix here and the
`-disable-vp=true` fix remain UNPROVEN; the Zink/Vulkan truncation question
above is still open and needs a real PGO dispatch (`-f webkit_pgo=on`) to
re-reach.
