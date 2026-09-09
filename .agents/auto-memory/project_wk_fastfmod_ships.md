---
name: project_wk_fastfmod_ships
description: RESOLVED 2026-09-09 (PR #194) — the Zen3/Zen4 split (0.92-0.94 / 1.16) is FIXED, spread now 0.99-1.05 across 7763/9V74/6973P-C; root cause was an unpredictable normalisation branch, not the divide; do not re-derive the tzcnt-strip/chunked-divide/cand-narrow algorithm, it is already on main
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

**Correction (PR #156, resolves the "2.57x unexplained" flag above).** The
browser-level `libm_fmod` row measured by `runtime-probe.cjs` does **not**
call libc `fmod` at all, for either engine. An LD_PRELOAD call-counter
attached to every live WebKit process (9 processes: MiniBrowser + WPE aux)
saw **zero** libc `fmod` calls, with BOTH the original `%` operand (folds to
a `2^32` divisor at JIT time) and a prime-number divisor substituted to defeat
constant-folding. JSC (and V8) carry their own internal double-modulo op —
this kernel never crosses the libc boundary, same shape as
[[project_wk_jit_kernels_are_at_the_floor]] though for a different reason
(engine has its own impl, vs. engine emits identical JIT code).

PR #155 claimed "a prime divisor restores the libc fmod path" — that was
**wrong**, refuted by the same call-counter, and corrected in #156. A prior
container-wide LD_PRELOAD A/B ("as-shipped" vs "forced") had read completely
flat (175ms both arms) and was misread as evidence either way; the real
reason it was flat is `pw_run.sh` does `export LD_PRELOAD=…` unconditionally,
so it overwrites whatever the container env set — both arms always ran with
the wrapper's own preload. Any future preload experiment must patch the
wrapper script itself, not the container env.

So: the 2.65x-3.12x `libm_fmod` browser ratio is real but is a JSC-internal-
codegen-speed finding, not a musl-vs-glibc libc finding — this fastfmod shim
does nothing for it (nothing to intercept). The shim still earns its keep for
any C/C++ path that calls libc `fmod` directly (none identified in-browser so
far); "do not quote parity" above stands, now for a different reason.

**SECOND correction (2026-09-08, PR #167/#170) — the #156 "zero libc calls"
finding above was ITSELF wrong.** The interposer that read zero had never
actually loaded; a version that proves it loaded shows **both** engines call
libc `fmod` for real. Official's WebProcess, preloaded with a deliberately
10x-slowed `fmod`: kernel goes 193→1943 ms and the counter sees **54,000,030**
calls. `fdiv`/`int_math`/`math_sqrt`/`mod_int32` stay exactly 1.00 across
default / FTL-off / DFG+FTL-off tiers — only `mod_frac_double` (2.43x) and
`mod_int_double` (3.12x) move, which also kills the JIT-tier theory: this is
the native double-modulo routine, not codegen or tier.

On the CI Zen4 core (ratios do NOT transfer across CPUs — a dev-box reading
had glibc and the old shim nearly tied, which inverted the ranking and stalled
the fix): musl raw 372.2 vs glibc 64.3; the OLD bit-per-iteration shim shipped
at 168.3 (2.6x glibc — exactly the browser's 2.60 `libm_fmod` reading, so the
row was fully accounted for). Root cause of the old shim's slowness: it walks
the exponent difference one bit at a time; glibc's fast path is a single
64/64 `div` with the divisor pre-shifted right (its low 11 bits are always
zero, so the dividend never grows), avoiding the slow 128-bit divider path a
naive port of the same trick falls into.

**Shipped (PR #167): a chunked-divide rewrite that BEATS glibc on the CI
core — 58.7 ms vs glibc's 64.3, bit-exact over 4,000,000 operands, 0
mismatches.** Browser result, n=10 three-arm same-machine probe: `libm_fmod`
**3.13 → 1.08**.

**Shipped (PR #170): removed a THIRD hardware divide** left in the rewrite's
own reduction (`mx %= my`) — both significands are 53-bit so `i < 2m` always
holds and a conditional subtract suffices. 269.5 → 170.2 ms locally,
bit-exact, gate green on all five steps. (Not yet re-measured browser-side in
this pass; the 1.08 above predates it.) The residual after #167 alone was
spotted BECAUSE the ratio moved when the same probe landed on a different CPU
(1.08 on one core, 1.33 on another) — a fully-fixed row should be CPU-
invariant, so a ratio that still moves with the core is the tell that a
hardware-dependent cost remains.

**Shipping trap found the same day (PR #168):** `test-and-publish.yml` has
`paths-ignore: playwright/alpine-browsers/**`, but the shim's source
(`fastfmod/**`) and `strip-bundled-libs.sh` live exactly under that path, and
the **consumer** image is what compiles them — a source change there merges
green and republishes `latest` with NOTHING changed. #167's fix only reached
`latest` earlier by accident of an unrelated commit landing alongside it.
Also: a `workflow_dispatch` of `test-and-publish` is push-gated and never
publishes at all — to measure a dispatched build, probe the GHCR sha-tagged
image the run itself produced, don't wait for a publish that won't happen.
[[project_tp_paths_ignore_ships_nothing]]

## The ratio per CPU model, and the transfer gap (2026-09-08)

`libm_fmod`'s ratio is a measurement, not a runner fingerprint — only its
ABSOLUTE value fingerprints the machine. n=10 per arm, both arms in the same
job: EPYC 9V74 reads 1.12 with NON-overlapping ranges (ours 65-68, official
58-61); EPYC 7763 reads 0.93 and 0.96, overlapping. Our arm is flat
(66/64/65) across both models; the OFFICIAL arm is what moves (59 vs 68-69).
So the reference wanders, and on the 9V74 we are genuinely ~12% behind.

That deficit is a TRANSFER gap, not a missing optimisation. The measured
image `sha-ea0b8149` is post-#170, compiled `gcc -O2 -fPIC` exactly as
`run-gate.sh` compiles it, preload wired. Isolated on a 9V74 the shim is
58.7 ms against glibc's 64.3 (0.91x); in-browser on a 9V74 the same shim
reads 1.12. Same algorithm, same core class, opposite verdict — next
instrument is `perf record` of the WebProcess during the kernel, not another
fmod candidate.

Do NOT re-derive the tzcnt strip or the chunked divide: both are ON MAIN
since #167/#170. A pre-Zen dev box inverts the ranking between candidates
(the file header records 247 vs 241), and this laptop has
`perf_event_paranoid=4` so it cannot even count cycles — time fmod
candidates in CI. See [[feedback_diff_against_main_before_optimising]].

## RETRACTION and final verdict (2026-09-08, PR #189/#190/#191)

**The "transfer gap" theory above is wrong.** Chasing it, a from-scratch
re-derivation of glibc's `tzcnt`-strip trick reached bit-exactness and a
green gate — and turned out to be a **revert wearing an optimisation's
clothes**: the checkout doing the chasing (`fix140`) was stale and still had
the pre-#167 cmov-only shim, while `origin/main` already carried both the
strip and the chunked divide. The file's own header warns about exactly this
("candidates are timed in CI, never locally") but says nothing about a stale
branch shadowing a shipped fix — check `git diff origin/main -- <file>`
*before* optimising anything, every time
([[feedback_diff_against_main_before_optimising]], second occurrence this
session backing the same rule).

**Differential profile, `libm_fmod` kernel added to `wk-hotloop.cjs`,
against the exact proof image (`sha-ea0b8149…`, post-#170):**

| CPU | ms/round ours/off | fmod DSO share/round | JIT share/round | row |
|---|---|---|---|---|
| EPYC 7763 (Zen 3), n=3 profiles | 66.8-67.4 / 70.6-71.1 | 17.1% / 17.4-17.7% | ~1.0 | 0.94-0.95 |
| EPYC 9V74 (Zen 4), n=1 profile | 51.5 / 46.4 | 19.73% / 18.93% | 0.96 | 1.11 |

Three things this settles, all previously open:
1. **The preload reaches the WebProcess** — `libfastfmod.so` is a named DSO
   carrying real % of the window; 1.12 was never an un-shimmed musl path.
2. **No transfer gap** — the row ratio tracks the fmod DSO ratio exactly on
   both CPUs (0.91-0.94 vs 0.92-0.95; 1.16 vs 1.11), and JIT sits at or below
   parity on both, so the JS loop isn't hiding anything. On official's arm
   the symbol resolves to one name, `fmod`, at 19.73% on Zen 4.
3. **The "our arm is flat across CPUs" claim earlier in this file is also
   wrong** under this instrument — `wk-hotloop.cjs`'s isolated kernel and
   `runtime-probe.cjs`'s `libm_fmod` row disagree on ABSOLUTE movement (ours
   gains 1.30x Zen3->Zen4, official gains 1.52x) while agreeing exactly on
   every RATIO. Don't mix the two instruments' absolute numbers; ratios are
   what transfers.

**Root cause of the Zen-4 loss:** glibc's `fmod` gets ~15% faster on Zen 4
(68-69ms -> 59ms) while our chunked-divide shim doesn't move — both are
divide-based, so this is a microarchitecture-specific division cost glibc's
code path avoids and ours doesn't yet. Left open deliberately: identifying
the exact instruction needs instruction-level profiling against a
symbol-carrying glibc (official's shipped libm is stripped, samples land on
bare addresses) — a new campaign, not a loose end of this one.

**Runner fleet mix (2026-09-08, from 19 past perf-probe artifacts' recorded
CPU field) — the base rate for "which silicon did this run land on":**

| CPU | share |
|---|---|
| AMD EPYC 7763 (Zen 3) | 50% |
| AMD EPYC 9V74 (Zen 4) | 25% |
| Xeon Platinum 8573C | 10% |
| Xeon Platinum 8370C | 10% |
| Xeon 6973P-C | 5% |

~1-in-4 odds of landing a 9V74 per dispatch; three 7763s in a row before
finally hitting one on attempt 6 (then again on a separate fishing run,
attempt 9) is within normal variance (~12% and ~10% respectively), not a
fleet change. Useful anywhere pairing an arm to a specific CPU model matters
— it turns "keep re-dispatching until you get the CPU you want" from a guess
into a costed decision. `wk-perf-record.yml` didn't record the runner CPU at
all until this session (one-line fix, folds into every future profile).

**Final scoreboard before the fix:** Zen 3 **0.92-0.94** (5 independent
measurements — 3 profiles + 2 probes), Zen 4 **1.16** (1 profile + 1 probe,
non-overlapping ranges so real, not noise). `fastfmod.c`'s header and
`Dockerfile.alpine`'s preload comment carried this split (PR #191) — the old
text claimed an unqualified win and had gone from incomplete to actively
misleading once the Zen-4 reading existed.

## RESOLVED (PR #194, 2026-09-09) — root cause was a branch, not the divider

A subagent dig (`diag/fmod-zen-divider`) was handed "the Zen-4 divider is
slower" as the leading hypothesis. **It's dead, measured directly:** `div r64`
is 14.0 cycles latency / 7.0 throughput on BOTH Zen 3 and Zen 4 — identical.
The 9V74 is simply 11.5% lower-clocked (2.847 vs 3.216 GHz). A raw `div`
ladder at both implementations' exact operand shapes agrees within 0.2%
(Zen's divider is quotient-bit-count-driven, both sides produce the same
21.49-bit quotient), and both implementations issue exactly **one** hardware
divide per call — proven twice, by stream simulation and by glibc's Barrett
loop taking 0.00% of profile samples.

**The real cause: our normalisation tail carries an unpredictable branch,
glibc's doesn't, and Zen 4 rewards the branchless tail more.** Our loop —
`while ((i & IMPLICIT) == 0) { i <<= 1; ex--; }` — is a geometric coin flip
on the probe's operand stream (p=1/2, mean 1.0 iterations); glibc normalises
branchlessly (`bsr/xor $0x3f/shl`). Mispredict penalty is a fixed **4.0
cycles on both microarchitectures** — a wider core can't shrink it — while
glibc's longer straight-line chain is exactly what a wider core eats better
(non-div cost: glibc 17.4→10.8 cycles Zen3→Zen4, ours 13.3→10.7). Our Zen-3
win lived entirely in that non-div work; Zen 4 converges both arms to ~10.7
and the win evaporates.

**The fix (`cand-narrow`):** keep significands at 53 bits, spend the
divisor's own trailing zeros first then at most 11 bits of dividend headroom
(glibc's reduction shape), replace the coin-flip loop with `__builtin_clzll`.
Do NOT cherry-pick just the `clz` half — alone it *hurts* Zen 3 by 14%; the
win is the pair. Isolated C bench: spread went 0.85-1.18 → 0.94-0.99 across
four CPU models.

**Browser validation matters — the isolated bench over-promised.** Predicted
Zen 4 0.97, browser measured **1.05**; predicted 6973P-C (Intel) 0.99,
browser measured **1.02**. The isolated instrument is directionally right but
optimistically biased by a near-constant 0.03-0.08 — a second instance of
this row's isolated-vs-browser disagreement pattern
([[project_wk_fastfmod_ships]] itself already shows this once above). Do not
merge a fix for this row on C-microbenchmark numbers alone; browser-probe it
across CPU models first.

**New finding: the shipped shim's worst case was Intel, not Zen 4.** Xeon
6973P-C read **1.26** — worse than either AMD part. Every prior
characterisation of this row (including PR #191's header) was AMD-only and
understated the problem.

**Merged scoreboard, browser-measured, n=10, candidate+shipped+official
control all in one job per draw:**

| CPU | shipped | candidate |
|---|---|---|
| EPYC 7763 (Zen 3) | 0.95 | 0.99 |
| EPYC 9V74 (Zen 4) | 1.13 | 1.05 |
| Xeon 6973P-C | 1.26 | 1.02 |

Worst case 26% over parity → 5%. Fleet-weighted (50/25/25) ~1.07 → ~1.01.
Zen 3 does cost 5% versus the old shim, exactly as the C bench warned, but
still lands at/under parity (0.99), not across it. Merged `543d7b3`.

**Companion bug found and fixed in the same campaign (PR #193):**
`playwright/bench/wk-hotloop.cjs`'s `libm_fmod` kernel divided by `4294967296`
(2^32) — the exact power-of-two its own adjacent comment warns against — so
every `wk-perf-record` profile of this row since that kernel was added
profiled a *different* operand stream than the row it purported to explain.
Same trap family as [[project_fmod_microbench_is_vacuous]], recurring in a JS
harness instead of a C one this time. `runtime-probe.cjs`'s prime divisor
(4294967291) was never affected.

**Naming note that came out of reporting this:** [[feedback_name_candidate_not_arm]]
— the build under test is "candidate", never "arm" (the neighbouring PR-table
columns are CPU models, so "ARM" misreads as the instruction set).

Residual: the row is not ≤1.00 everywhere — 1.05 on Zen 4, 1.02 on Xeon,
within 5% on the worst part. "Every row at or below parity except
`libm_fmod`, which is within 5% on the worst part" is the accurate current
claim, not "closed".

