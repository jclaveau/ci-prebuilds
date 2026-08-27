---
name: project_ff_build_missing_pgo_lto_jemalloc
description: RESOLVED — musl Firefox's gap vs Playwright's own build was the ALLOCATOR, not the PNG encoder, not musl's string routines and not the missing PGO; mimalloc preloaded in the launch shim takes screenshot 0.69x->0.96x and launch 0.83x->1.02x (PR #110)
metadata:
  type: project
---

`firefox/mozconfig.overlay` sits on aports' `mozconfig` and adds ONLY
`--with-ccache=sccache`. Everything else lives in the APKBUILD's `build()`,
which we never run because we call `./mach build` ourselves. So we lose:

| lever | where aports puts it | ours |
|---|---|---|
| PGO | `optimised-mozconfig` (`--enable-profile-{generate,use}=cross`) | absent |
| LTO | `optimised-mozconfig` (`--enable-lto=cross`) — **not** in base | absent |
| mozjemalloc | base has `--disable-jemalloc`, so musl malloc | absent |

`grep -c lto` on the base mozconfig returns **0** — LTO is not a base option,
it is added beside PGO. An earlier note here claiming "LTO-but-not-PGO" was
wrong; skipping `build()` drops both together.

**Why it is the leading candidate.** perf-firefox (run 32782133911, three arms,
one runner) puts our build's only real deltas at `screenshot` 1.20, `launch`
1.16, `layout` 1.09 — all C++ — while every JIT-executed kernel (`eval_rtt`,
`int_math`, `js_alloc`) is at parity, which is the shape a missing C++
optimisation makes. The same lever on chromium in this repo went geomean
1.42 → 1.28 (PGO), → 1.12 (PGO+ThinLTO, super-additive)
([[project_chromium_perf_arms_1_62]]).

**Cost ladder, cheapest first:**
1. **allocator** — `LD_PRELOAD` a different malloc at RUNTIME, no rebuild.
2. **LTO only** — one build (~5-6h), no profiling infrastructure.
3. **PGO+LTO** — instrumented build + `build/pgo/profileserver.py` under
   xvfb + dbus + `./mach clobber` + optimised build, so ~2x a full build.

**How to apply:** do not quote our FF as "optimised like the distro build" —
it is the distro's SOURCE with none of the distro's optimisation. Measure with
perf-firefox's three arms, not a two-arm ours-vs-official
([[project_alpine_browser_perf_vs_glibc]]).

**2026-08-25 — jemalloc is IMPOSSIBLE on musl. Do not re-add it.** Run
32800234529 died ~2 min into `memory/`:

    memory/build/malloc_decls.h:61:1: error: exception specification in
    declaration does not match previous declaration
      NOTHROW_MALLOC_DECL(free, void, void*)
      MOZ_MEMORY_API return_type name##_impl(...) noexcept(true);
    /usr/include/stdlib.h:43:6: note: previous declaration is here
      void free (void *);

`mozmemory_wrap.h` declares the `*_impl` overrides `noexcept(true)`; glibc
marks those `__THROW`, musl does not, so every declaration mismatches. So
aports' `--disable-jemalloc` is a musl **requirement**, not an optimisation it
declined — the table above was wrong to list it as a missing lever.

Configure ACCEPTS `--enable-jemalloc`; only the compile rejects it, so this is
a cheap 30-min failure rather than a late link failure. That is also why
`memory/build/` never compiles in our builds: it is gated on `MOZ_MEMORY`.

**The allocator win is still real, but only at RUNTIME.** The LD_PRELOAD A/B
stands (mimalloc vs musl malloc, one container, back-to-back: eval_rtt -33%,
launch -21%, layout -12%, with `libm_fmod` +1% and `locator_click` -2% flat as
controls). Delivering it means preloading an allocator in the runtime image,
NOT a mozconfig option — and `mimalloc2-insecure` / `scudo-malloc` are already
in the FF builder's apk list. Open: LD_PRELOAD in the published image hits
every process in the container (node included), so it needs scoping to the
browser launch, and the `-insecure` variant trades hardening for speed.

**So the ladder is now:** LTO (arm 32802019356) → runtime allocator → PGO.

**2026-08-25 — LTO MEASURED, and one run would have lied.** Arm
`perf/firefox-lto-jemalloc` (3909df8) built in 4h18m with `--enable-lto=cross`
and did NOT OOM the 4-vCPU/16GB runner, so `cross,thin` is unnecessary.
Two ours-vs-ours A/Bs, each arm on one runner (32819403911 Xeon 8573C,
32819736659 EPYC 9V74), ratio = lto/baseline:

| metric | run 1 | run 2 | verdict |
|---|---|---|---|
| layout | 0.91x sig | 0.90x sig | **real, ~10%** |
| launch | 0.84x n.s. | 0.96x sig | **artifact** |
| screenshot | 0.97x n.s. | 0.98x n.s. | no effect |
| libm_fmod | 1.03x | 1.04x | slightly SLOWER |
| int_math / js_alloc / locator_click / click_force | 1.00x | 1.00x | flat controls |

**launch's 16% was run-to-run noise:** the BASELINE arm alone moved
856.6 -> 724.6 ms between runs (18%). A single run would have credited LTO with
closing the 1.16 launch gap; it closes ~4% of it.
[[feedback_check_reference_stability_across_runs]],
[[feedback_size_verification_to_failure_rate]]

**So the three gaps have three different owners:**
- `layout` 1.09 → LTO. Fixed.
- `launch` 1.16 → the ALLOCATOR (mimalloc LD_PRELOAD -21%), which cannot ship
  as mozjemalloc on musl, so it needs a runtime preload in the image.
- `screenshot` 1.20 → still unexplained. It has now survived the PNG encoder
  (#102: bytes fixed, time unchanged), the allocator (-5%) and LTO (n.s.).
  Each of those moved OTHER metrics, so they were real levers that simply do
  not touch this one. Full-viewport capture/readback remains the standing
  hypothesis ([[project_ff_png_encoder_gap]]).

**LTO vs official (32823363394, EPYC 7763, official/ours so <1 = we are slower):**
`layout` **0.98x n.s.** (was 0.86x — CLOSED, exactly as the ours-vs-ours 0.90x
predicted), `launch` 0.90x (was 0.83-0.91x — unchanged, consistent with LTO
buying only ~4%), `libm_fmod` 1.54x ours-faster, controls flat.

**`screenshot` read 0.86x here against 0.68-0.69x before — do NOT bank that.**
Ours-vs-ours says LTO does nothing to screenshot (0.97x, 0.98x, twice), and the
absolute wanders wildly BETWEEN runs: ours 325.0 / 304.9 / 240.7 / 211.3 /
194.3 ms across five probes, official 222.2 / 209.0 / 206.3. So the
ours-vs-official screenshot ratio is unstable run-to-run and only the
within-run controlled A/B can speak to it. Repeat before quoting any screenshot
number vs official. [[feedback_check_reference_stability_across_runs]]

**2026-08-25 — RESOLVED. The gap was the ALLOCATOR, and nothing else.**

`nm -D` on the two shipped `libxul.so` (both firefox 153.0, version-matched,
extracted with `docker create` + `docker cp`, controls 2839/3041 undefined
symbols so the zeros are findings not a missing-tool artifact):

| | official | ours |
|---|---|---|
| `malloc` undefined | **0** (mozjemalloc linked in) | **1** (musl) |
| memcpy/memmove/memset/memcmp/strlen undefined | **0** | **5** |
| png/zlib/jpeg/webp/vpx/pixman/icu | bundled | system `.so` |
| DWARF | stripped + `.gnu_debuglink` | **34 MB of `.debug_*` + `.symtab`** |

Preloading mimalloc in the firefox launch shim, ours-vs-ours on one runner
(32833439914) then vs official (32833725968):

| metric | before | after |
|---|---|---|
| screenshot | 0.69x | **0.96x** |
| launch | 0.83x | **1.02x** |
| eval_rtt | 0.86x | **1.00x** |

`int_math` and `locator_click` identical to the ms on both arms. Shipped as
PR #110 (shim-scoped, not ENV, so node / PartitionAlloc / bmalloc are untouched;
conformance runner gets the same line for tested==shipped).

**The other half of the same symbol-table difference is INERT.** An AVX2 shim
answering all five string routines moved nothing — every row inside the ±6%
drift — with a marker file proving it loaded into **34 processes**. So "official
resolves it internally and we call musl" is a real difference whose cost is
zero here. Same shape of evidence, opposite conclusion: only the A/B separates
them. [[feedback_control_excludes_one_mechanism]]

**PGO is very likely NOT in official** and needs no arm: aports' PGO emits a
jarlog and reorders `omni.ja`, and official's `omni.ja` is plain alphabetical,
2458 entries, identical ordering to ours. Building it would put us PAST
official, not close a gap.

**Allocator variants, measured not assumed.** jemalloc = tie (mimalloc leads
screenshot/launch/eval_rtt but inside screenshot's own 15% cross-run spread,
205.8-237.3 over four runs). mimalloc2 SECURE = clear loss, -10..-15% on every
allocation-heavy row with controls flat (32834354468) — so `mimalloc2-insecure`
is a measured choice, not one inherited from aports.

**Do not quote `layout`.** Across five runs it reads 70, 70, 98, 99, 102 ms —
bimodal, not noise around a mean.

**`conformance-firefox` is SKIPPED on `pull_request`** (as are build-firefox and
smoke-firefox), so a green PR does NOT validate a browser change here — dispatch
`pw-conformance.yml --ref <branch>` with `image_ref`/`artifact_rev` and gate on
that. [[project_conformance_only_dispatch_gap]]

**2026-08-27 — two corrections to the entries above.**

**The "loaded into N processes" marker evidence is CHROMIUM's, not firefox's.**
`FAST_STRING_MARKER` is wired only in `.github/workflows/chromium-gap-probes.yml`,
and `playwright/bench/fast-string-preload.c`'s own header scopes itself to "the
five routines our chrome-headless-shell imports from musl". This file reads as if
that proof covers firefox. It does not: **the firefox mimalloc preload has never
been empirically shown to reach a content process.** The mechanism says it should
— Gecko's `security/sandbox/linux/launch/SandboxLaunch.cpp::PreloadSandboxLib`
appends the parent's `LD_PRELOAD` after `libmozsandbox.so` and records the
original in `MOZ_ORIG_LD_PRELOAD` — and `dom_churn` at 0.77x is consistent with it,
but that is inference. Settle it in ~5 min on the shipped image:
`grep -c MOZ_ORIG_LD_PRELOAD /proc/*/environ` (Gecko sets it ONLY on children
whose inherited value it rewrote), or `MIMALLOC_SHOW_STATS=1` and count the
per-process stat blocks. A count of 1 means every layout number is measuring
nothing. [[feedback_prove_the_lever_is_connected]]

**LTO was measured, twice, and never shipped because of a false comment.**
`apply-and-build.sh` (near line 519) claims "the musl producer build (aports'
mozconfig) keeps LTO on for shipping perf". `grep -c lto` on that mozconfig
returns **0** — LTO lives in the APKBUILD's `optimised-mozconfig`, which we never
run. So we ship a non-LTO firefox. Two independent ours-vs-ours A/Bs on different
runners measured `layout` **0.91x and 0.90x** with every control flat, and then
0.98x vs official — closed. The arm built in **4h18m on the 4-vCPU/16 GB runner
without OOM**, so `cross,thin` is unnecessary. Caveat: every LTO measurement
predates mimalloc and the allocator moved `layout` -12% on its own, so the two may
overlap rather than add — one `ff-perf-ab` with `preload_a == preload_b` settles
it. Gate it the way the void hardening arm should have been:
`readelf -S libxul.so | grep '\.text'`, baseline **118 846 320 B**; byte-identical
means the arm is void. [[project_ff_hardening_arm_unresolved]],
[[feedback_verify_ab_varied_the_variable]]

**Closed on source evidence, not measurement — stop proposing these:**
- **Hardening is not a differentiator.** `build/moz.configure/toolchain.configure`
  adds the flags in the default no-flag case, so OFFICIAL carries the identical
  set. This retires the parked `MOZ_HARDENING_CFLAGS` rebuild. Two refinements:
  `-ftrivial-auto-var-init=pattern` is `if debug:` only, so neither side pays it,
  and STL hardening is off on both (`debug or WINNT or OSX`).
- **`-O2` vs `-O3`.** `moz_optimize_flags` returns `-O2` for Linux; ours is `-O2`
  via `: "${CFLAGS:=-O2 -pipe}"`. Same level. `-O3` only arrives under PGO, which
  official does not use either.
**2026-08-27 — the preload DOES reach content processes. Settled, in minutes.**
The "loaded into N processes" proof recorded above was chromium's; firefox's had
never been shown. Run the shipped image, drive one `page.goto` + screenshot,
then read `/proc/*/maps`:

    SUMMARY firefox_procs=6 with_mimalloc_mapped=6 with_moz_orig=5

All six (parent + five children) map mimalloc, five mappings each, and the five
children carry `MOZ_ORIG_LD_PRELOAD=/usr/lib/libmimalloc-insecure.so.2` exactly
as Gecko's `SandboxLaunch.cpp::PreloadSandboxLib` documents — it appends the
parent's LD_PRELOAD after `libmozsandbox.so` and records the original. So every
`layout`/`js_alloc` number is the whole browser, not the parent alone.

**2026-08-27 — NODE's allocator is worth another 8-13% on `eval_rtt`.** The shim
deliberately scopes the preload to firefox "so it reaches firefox and its
children and not the Node.js driving them". But `eval_rtt` is 500 pipe round
trips through that node, and it is the one row where we were still behind
official at n=5 (1.017). Setting `LD_PRELOAD` on the PROBE CONTAINER varies the
driver's allocator alone — the shim re-exports its own, so firefox is untouched:

| run | CPU | arm order | musl node | mimalloc node | gain |
|---|---|---|---|---|---|
| 33065282215 | Xeon 8370C | musl first | 343.2 | 318.3 | **+7.8%** |
| 33065574061 | Xeon 8573C | mimalloc first | 313.5 | 277.0 | **+13.2%** |

Same direction on two CPUs with the arms in opposite order, and well outside
`eval_rtt`'s own spread (1.8% / 6%). The browser-only controls stay flat both
times — `click_force` 1.000/0.999, `locator_click` 1.000/1.000 — which is what
makes it readable at n=1.

**Shipping it is a UX decision, not a perf one.** `ENV LD_PRELOAD` on the
consumer image reaches every process a user runs in the container (their test
runner, pnpm, their app), and the `-insecure` variant drops mimalloc's
hardening. That is exactly the scoping the shim comment chose against, so it
needs jean's call rather than a quiet flip.
[[project_ff_probe_pinned_rows_and_timer_grain]]
**2026-08-27 — the open question above ("never empirically shown to reach a
content process") is ANSWERED, see the `firefox_procs=6 with_mimalloc_mapped=6`
measurement earlier in this file.** Both entries were written the same day by
parallel agents and the merge put the answer before the question; the answer is
the later fact. The LTO arm it asks for is building as run 33063836129, with
`preload_a == preload_b` so the allocator is held constant, and
`apply-and-build.sh` now asserts `MOZ_LTO` in autoconf.mk and prints libxul's
`.text` so the arm cannot come back void unnoticed.

**2026-08-27 — the node fix takes `eval_rtt` BELOW official.** ff-perf-ab
33066228735, our artifact with the node preload against `official`, same runner,
same EPYC 7763 model as the n=5 baseline it is being compared with:

| row | baseline (n=5, no node fix) | with node preload |
|---|---|---|
| `eval_rtt` | 1.017 | **RETRACTED — see below** |
| `layout` | 1.087 | 1.120 (n=1) |
| `dom_churn` | 0.805 | 0.756 |
| `libm_fmod` | 0.667 | 0.667 |
| `int_math` / `js_alloc` / `click_force` / `locator_click` | 1.000 | 1.000 / 1.000 / 1.001 / 1.000 |

**The 0.957 was one draw and it did not reproduce.** Draw 2, same CPU model,
read **1.022**: official's own arm moved 365.9 -> 390.7 ms between the runs while
ours carried a 447 ms outlier among three samples. The n=10 baseline had already
said so (23/100 cross-pairs, tied) — a ~2% difference is not readable off n=1 per
arm however clean the A/B that produced it.

What survives is narrower: **preloading mimalloc into node improves OUR OWN image
by 7.8-13.2%** (two runs, tight within-run spreads, flat browser-only controls).
That is a real gain and worth shipping on its own merits. It is NOT evidence that
we beat official on that row, and it must not be quoted as such.

Three rows reproduce across everything measured this session — n=5, n=10, and four
`ff-perf-ab` draws on three CPU models: `layout` 1.065-1.12 (slower, the one real
deficit), `dom_churn` 0.756-0.82 (faster) and `libm_fmod` 0.66-0.67 (faster, and
see the kernel's own comment before reading that as a libc verdict). **Every other
row wanders between draws and should be quoted as parity — not as a win, and not
as a work item.**

Do not read `context_page` (1.061), `goto_cold` (1.009) or `screenshot` (1.025)
off this run — it is n=1 and those rows carry the outliers (`context_page` has a
1050 ms sample among ~230 ms ones). At n=5 they are 0.965 / 0.968 / 1.009.

So after the node preload, **`layout` is the only row still above 1.00** that is
not pinned by physics.

**The SECURE mimalloc captures nearly all of the node win** (33066499518,
insecure vs secure on node, firefox shim held at insecure on both):
`eval_rtt` 356.7 vs 363.9 = **0.98**, i.e. a ~2% gap between the variants
against the 8-13% gap versus musl malloc. Controls flat (`int_math` 1.000,
`locator_click` 1.000, `layout` 1.000, `libm_fmod` 1.014).

n=1 and 2% sits inside `eval_rtt`'s own 6% spread on that run, so the honest
statement is "secure ~= insecure, both much better than musl malloc" rather
than a ranking between the two. That matters because it removes the security
objection from the shipping question: `libmimalloc.so.2` keeps mimalloc's
hardening and still gets the win, so the choice does not have to be `-insecure`.
Note this is the opposite of the BROWSER-side finding, where mimalloc2 secure
was a clear 10-15% loss — the driver is not allocation-bound the way gecko is.
