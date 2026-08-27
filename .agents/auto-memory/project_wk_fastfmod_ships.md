---
name: project_wk_fastfmod_ships
description: musl's fmod is 3.2x glibc's and it is all of libm_fmod; a branchless drop-in preloaded under WebKit closes it, gated in CI on a bit-exact differential that caught a NaN-sign bug on its first run
metadata:
  type: project
---

Shipped in PR #131 (stacked on #123), issue #126.
`playwright/alpine-browsers/webkit/fastfmod/` + `.github/workflows/
wk-fastfmod-gate.yml`.

**The finding.** `libm_fmod` (5.35x EPYC 7763 / 6.31x EPYC 9V74 / 7.65x Xeon
8370C) is musl's `fmod`, NOT JSC. Both engines call libc the same 3,000,000
times per kernel (30,000,033 ours vs 30,000,057 official, interposed and
counted); `(i*1.5) % 1024.25` — the same call at small magnitudes — is 1.07x;
`Math.sqrt` and an int-only `%` are at parity. musl walks the exponent
difference one bit per iteration with a data-dependent branch, so ~21
unpredictable branches per call at the probe's operands.

**How far it actually gets, measured in containers on ONE host** (an earlier
version of this note compared a musl CONTAINER against my glibc HOST — two
machines, the exact error [[project_perf_probe_ratio_is_cpu_dependent]] warns
about), `-fno-builtin-fmod`, glibc arm gated at 8,999,999 observed calls:

```
per 9M calls      ms      ns/call   vs glibc
musl             465.2      51.7      3.02x
this rewrite     196.2      21.8      1.27x
glibc            154.2      17.1      1.00
```

2.37x faster than musl, and it does NOT reach glibc. In the browser it is
further off: perf-probe puts the arm at **2.57x** official (two draws, both
EPYC 7763, 2.57 both times) against roughly 10x before. Why C says 1.27x and
the browser says 2.57x is unexplained — JIT call sequence, CPU, or both. Do
not quote "parity".

**Ship shape.** One more entry in the `pw_run.sh` LD_PRELOAD beside mimalloc.
Reaches MiniBrowser + WPE aux processes only. `LD_PRELOAD` failure is
non-fatal (ld.so warns and continues), so nothing depends on it for
correctness.

**MUST be self-contained** — no dlsym, no RTLD_NEXT, no fallback. The
prototype deferred NaN/subnormal corners to `fmod()`, which is fine in a normal
function and infinite recursion once the object exports that symbol.

**The gate is the deliverable, not the speedup.** Build ONE vectors binary,
run it with and without the preload, diff 64 bucket digests over 7,501,023
operand pairs — so the reference is musl itself and the subject is the shipped
.so. It refuses three things: a run where fmod was inlined away (call counter
must see >= 7.5M), a preloaded run that did not load the preload (greps
`/proc/self/maps`; ld.so only warns), and itself (a corrupted twin generated
from the same source must fail — it may HANG rather than answer wrongly, so
bound it with `timeout` and treat 124/137 as a rejection).

Two traps it cost me:
- `set -e` aborts on the timeout before `BROKEN_RC=$?` runs — use
  `|| BROKEN_RC=$?` or the gate fails with the control's own rc.
- the timing loop must write to STDERR, or it pollutes the diffed stdout with
  the very number that differs between arms by design.

**It caught a real bug on run one**: 3 of 64 buckets, localising to 2 of 1024
edge cases — `fmod(NaN, -NaN)` and `fmod(-NaN, NaN)`, where musl propagates the
FIRST NaN operand's sign and `(x*y)/(x*y)` does not. Fix is `x + y` for the
NaN-operand case. Not findable by reading the code.
[[project_fmod_microbench_is_vacuous]]
