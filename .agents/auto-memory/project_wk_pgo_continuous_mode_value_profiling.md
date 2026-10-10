---
name: project_wk_pgo_continuous_mode_value_profiling
description: LLVM continuous-mode PGO (%c) never writes the value-profile section IR instrumentation emits at indirect calls, so every C++ image reads back as "truncated profile data" and one bad input fails the whole merge; shipped fix -mllvm -disable-vp=true (95f8ef7) now SUPERSEDED by a design that avoids continuous mode entirely via a clean window.close() exit, recovering full value profiling — planned as candidate C, not yet shipped
metadata:
  type: project
---

`-fprofile-continuous` syncs **counters** to the profraw file and nothing else.
IR instrumentation still emits value-profiling sites at every indirect call, and
the raw header still declares that section, so `llvm-profdata` reads past EOF and
rejects the image with `truncated profile data`. **One rejected input fails the
entire merge** with `error: no profile can be merged` — so a C++ tree whose every
image carries virtual dispatch loses all of its profiles at once.

WK run 36024117406: the `%m` fix ([[project_wk_pgo_multidso_sigbus_percent_m]])
worked — no SIGBUS, smoke run wrote 7 files across 3 pids and 4 image hashes —
and all 7 were truncated.

**Reduction** (`$S/pgocont/run5.sh`, `run6.sh`; alpine:edge clang 23.1.2, musl):
two instrumented `.so`s plus a main dispatching through a function-pointer table,
killed by SIGTERM under `wk-%p-%m-%c`.

| build | main binary | the two .so | merge |
|---|---|---|---|
| `-fprofile-continuous` | 312 B, truncated | 36280 B, fine | `no profile can be merged` |
| + `-mllvm -disable-vp=true` | 296 B, fine | fine | 803 functions |

The libraries have no indirect call, which is why only the main binary breaks —
the earlier `run4.sh` repro passed purely because its main had none either.
Do not read a passing minimal repro as covering a C++ codebase.

**Also settled:** `-fprofile-continuous` **absent** while `%c` is in the path gives
`LLVM Profile Error: Neither __llvm_profile_counter_bias nor __llvm_profile_bitmap_bias is defined`
and **zero** files. WebKit wrote 7, so the flag did reach its compile — a grep for
the flag in a job log proves nothing either way, ninja does not echo command lines.

**How to apply:** any `%c` / `-fprofile-continuous` PGO build needs
`-mllvm -disable-vp=true` in `CMAKE_{C,CXX}_FLAGS`. Compile-only — `-mllvm` is an
unused argument at link time outside LTO. Cost is indirect-call promotion, which
continuous mode cannot feed either way. Shipped `95f8ef7` on `perf/wk-pgo`,
redispatched as run 36048405627.

**2026-09-24, superseding design: clean exit beats `-disable-vp` entirely.**
Neither chromium's `tools/pgo/generate_profile.py` nor Mozilla's
`build/pgo/profileserver.py` ever kills the browser under PGO — both exit
cleanly (crossbench process exit / `Quitter.quit()`), so neither ever needed
`%c`/continuous mode at all. WK's `train.html` loops `for(;;)` and the driver
kills it with `timeout -s TERM` — that one choice is the whole reason
`-disable-vp` was ever needed:
```
killed run → no atexit → need -fprofile-continuous → %c → no value-profile
section → truncated profile → forced -disable-vp → indirect-call promotion off
```
Tested directly: `window.close()` from the top-level page kills MiniBrowser
cleanly (rc=0, 1s vs control rc=124 at 25s) — and so do WPEWebProcess and
WPENetworkProcess (verified by shadowing `WEBKIT_EXEC_PATH` with logging
wrappers). All three then run through `atexit`, where
`__llvm_profile_write_file` lives.

Same two-`.so`-plus-indirect-call harness as the SIGBUS/VP tables above, arm
F = plain `-fprofile-generate` run to completion vs arm D (continuous +
`-disable-vp`, today's shipped `95f8ef7`):

| arm | exit | merge | indirect-call sites | sites with values | profiled targets |
|---|---|---|---|---|---|
| F plain generate, clean exit | rc=0 | 803 functions | 1 | 1 | 2 |
| D continuous + `-disable-vp` (shipped) | rc=143 | 803 functions | 0 | 0 | 0 |

Function count is identical either way — counters were never the problem.
Clean exit recovers the whole value-profile section (indirect-call
promotion), which `95f8ef7` throws away wholesale. Not cosmetic on a C++
tree that dispatches virtually everywhere.

**Plan (not yet shipped, no repo edits made):** candidate A (`36048405627`,
today's `-disable-vp` build) finishes as the "does PGO help at all" baseline.
Candidate C = same Speedometer2.1 corpus, clean exit instead of
continuous+disable-vp — single-variable vs A, isolates what value profiling
is worth. JetStream2 only after that as its own candidate (own driver/entry
point — worth it only if A shows PGO moves `js_alloc`). Build script loses
three things: `PGO_GEN_FLAGS` drops `-fprofile-continuous`, `PGO_GEN_CFLAGS`
drops `-mllvm -disable-vp=true`, `LLVM_PROFILE_FILE` drops the trailing
`-%c` (keeps `%m`). `train.html` must self-limit by **wall clock**
(`Date.now() > DEADLINE → window.close()`), not round count — a slow runner
must not outrun `PGO_CORPUS_SECONDS`, since a killed run under plain
`-fprofile-generate` now writes **zero** files (no continuous-mode safety
net). Outer `timeout -s TERM` becomes backstop-only, should never fire.

The fix for a killed PGO run was never `-disable-vp` — it was not killing
the run.
