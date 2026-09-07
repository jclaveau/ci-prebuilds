---
name: wk_fmod_is_libc_after_all
description: libm_fmod IS a libc call on both sides (my "zero calls" reading was a shim that never loaded); the fix is a chunked-divide fmod that beats glibc, and the row's ratio moves with the CPU because divides do
metadata:
  type: project
---

`libm_fmod` measures musl's `fmod` against glibc's, exactly as the name says.
Both engines call libc: a 10x-slowed `fmod` interposed into Playwright's OWN
image moved its kernel 193 → 1943 ms with **54 000 030 calls counted** in the
WebProcess.

This REVERSES what PR #156 recorded, and the error was mine twice over. The
counter that reported zero had not loaded, and I did not check that it had —
then a second run appeared to confirm it because the LD_PRELOAD never reached
`docker exec` at all (zsh does not word-split unquoted expansions, so
`${pre:+-e LD_PRELOAD=$pre}` arrived as one argument). An interposer that
reports zero must prove it was loaded before the zero means anything: a
constructor marker per pid plus a call counter.

The fix is in `fastfmod.c` and needs no browser rebuild — the shim is compiled
in the CONSUMER image:

| ms / 9M calls, EPYC 9V74 | |
|---|---|
| musl | 372.2 |
| bit-at-a-time shim (old) | 175.0 |
| glibc | 64.3 |
| chunked divide (new) | 58.7 |

Chunked divide is glibc's own `__fmod_finite` shape: shift the DIVISOR right —
a normalised significand always has 11 spare low bits — so the dividend never
outgrows 64 bits and the divide stays the fast `xor %edx; div` form, on the
identity `M = 2^k·M' => (X·2^k) mod M == 2^k·(X mod M')`. A later pass removed
a THIRD divide (`mx %= my` as loop setup, where one cmov subtract suffices):
269.5 → 170.2 ms locally.

**Why it kept being read wrong:** the ratio moves with the CPU because the cost
is divides, and dividers differ enormously between cores. The row read 1.08 on
an EPYC 9V74 and 1.33 on a Xeon 8573C with the same binary; on an older dev box
the new algorithm measured SLOWER than the loop it replaced (247 vs 241 ms),
i.e. the ranking inverted. That inversion is also what pointed at the extra
divide.

**How to apply:** time fmod candidates in CI on the core the images run on,
never locally, and never difference two runs on different CPUs
([[project_perf_probe_ratio_is_cpu_dependent]] — note `libm_fmod` is no longer
usable as the CPU fingerprint now that it is fast). `run-gate.sh`'s negative
control is COUPLED to the hot loop's shape by design: when the loop was
rewritten its sed matched nothing and the gate refused to run rather than
passing a vacuous control — keep that pairing.
