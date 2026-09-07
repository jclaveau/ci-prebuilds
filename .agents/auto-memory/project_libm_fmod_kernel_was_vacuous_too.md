---
name: project_libm_fmod_kernel_was_vacuous_too
description: the JS libm_fmod kernel shipped with a 2^32 divisor and reached libc ZERO times under WebKit, so every libm_fmod verdict — wins included — was measured on an engine-internal mask path
metadata:
  type: project
---

The probe's `libm_fmod` kernel shipped with divisor `4294967296` = **2^32**, which its own comment forbids. `fmod-call-counter.c` preloaded into every WebKit process (run 34048835048) counted **0** calls into libc while the row read 3.12x and was being quoted as musl's fmod. Restoring the prime `4294967291` does **not** bring libc back either: run 34049965630 counted **0** again. JSC serves `%` on doubles itself, and so does V8. The divisor still matters — the ratios moved when it was restored (chromium 1.00→0.99, firefox 0.64→0.51, webkit 3.12→2.65) — but what moves is the engine's own fast path, not libm.

**Why:** the C microbenches were already found vacuous for the same reason ([[project_fmod_microbench_is_vacuous]]); the JS kernel had the identical defect and nobody re-checked it. Worse, the comment that sat above it said the power-of-two theory "is WRONG — swapping 2^32 for the prime moves V8 by 3%, not 3x". That was measured on **V8, which carries its own fmod**, and generalised to all three engines. It does not transfer to JSC.

**How to apply:**
- Every `libm_fmod` number taken before PR #155 is void, **including the wins** — firefox's 0.64 as much as webkit's 3.12. Re-establish, don't carry forward ([[feedback_fixing_an_instrument_invalidates_its_verdicts]]).
- The shim [[project_wk_fastfmod_ships]] is mapped in `WPEWebProcess` with `LD_PRELOAD` in its environ and still never runs for this kernel — being loaded is not being used.
- `pw_run.sh` does `export LD_PRELOAD=…`, which **overwrites** anything inherited from `docker run --env`. A container-wide preload arm is not a second condition; inject through a replacement wrapper instead.
- Read the row per-engine, never as one libc verdict (issue #126). Only firefox behaves like
  something reaching a libm at all; the name is wrong for the other two.
