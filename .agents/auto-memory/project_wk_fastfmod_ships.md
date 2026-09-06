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
further off: against a TRUE no-preload control on one CPU model (EPYC 9V74),
`sha-cf1d73d` 6.24/6.33 -> shipped `edge` 3.07/3.12 — a **2.03x** improvement
landing at **3.09x** official. Why C says 1.27x and the browser says 3.09x is
unexplained — JIT call sequence, CPU, or both. Do
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


**A merged over-claim, and how it happened.** #131's commit body on main says
`libm_fmod` goes to "~0.97x. Under official, not merely closer." **It is
~3.09x.** The 0.97 came from an end-to-end run on a loaded laptop whose two
arms were internally inconsistent: `fastfmod` measured 1.13x slower there than
on a runner, `official` measured 3.6x slower. A slower machine slows BOTH — so
the official arm was anomalous and no comparison should have been drawn from
it. The tempting explanation (glibc's fmod being an IFUNC picking a slow
variant on an older CPU) is REFUTED: `readelf` shows one plain `FUNC` at
`fmod@@GLIBC_2.38`, no dispatch. Why that arm was slow is still unexplained.

Worse, the disproof was already in my own data: `sha-cf1d73d` predates BOTH
preloads and I had already probed it. I read the shipped 3.07/3.12 as
"confirms the preload is in edge" — true, and far weaker than the check I
should have run, because against 0.97 the same number is a refutation.
**When a number is supposed to prove a claim, difference it against the
claim, not against zero.** [[feedback_verify_ab_varied_the_variable]]
