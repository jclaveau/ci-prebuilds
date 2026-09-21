---
name: project_chromium_residual_gap_candidates
description: CAMPAIGN REOPENED 2026-09-19 — 5-run/cpu sample (18 draws, 4 fleet CPUs) proved startup's 1.05x IS noise (tz fix from PR #266 holds, that row stays closed) but nav 1.06-1.14x, layout 1.11x on EPYC 7763, input 1.02-1.06x, and screenshot 1.24-1.50x on Intel are real on 18/18 draws; per jean's rule the bar is now ≤1.00 not ≤1.05; new perf-record counter-table instrument (PR #268, kernels goto_warm/goto_cold) shows nav is the OPPOSITE of the old layout finding — +50% instructions but BETTER icache/iTLB than official, so not code-layout/orderfile, something executes more code per navigation; chromium residual was 12% after both knobs — dead: allocator, fonts, musl string routines, libc++ hardening, orderfile, CFI (parity arm SIGILLs), TLS, under-inlining, text stack (layout 0.99x), memset (same calls per iteration and same sizes as official to 0.5%/bucket, all interposable); clang 22-vs-23 is LIVE — layout 0.87x vs the shipped build on the slow runner (0.96 fast), vs official 1.40 (was 1.61), geomean 1.10; official codegen flags (aports' compiler.patch) DEAD at 1.01~; CFI SHIPPED 2026-09-17 (PR #260) — geo 0.94 vs prior shipped build, layout 0.74; CFI+snapshot-clang chain DEAD 2026-09-19 (snap/cfi geo 0.98, no measurable win); issue #259's hardening-removal ladder is further optimization, not gap-closing
metadata:
  type: project
---

After either perf knob, alpine chromium is still ~1.28-1.31x official on geomean
and 1.89x on layout ([[project_chromium_perf_arms_1_62]]). Run
**32502670597** (`chromium-gap-probes.yml`, all arms on one runner) killed three
of the five candidates.

**Measured** (`chromium-gap-probe.cjs`, 800 children, 300 forced reflows, ms):

| kernel | official | pgo | pgo+noble fonts |
|---|---|---|---|
| `layout_boxonly` | 299.4 | 471.4 (**1.57x**) | 463.0 (1.55x) |
| `layout_text` | 763.8 | 1170.1 (**1.53x**) | 1122.9 (1.47x) |

- **Candidate 2 (unbundled fontconfig/freetype/harfbuzz) — DEAD.** The gap is
  *fully present* on a subtree with no text node in it. Text shaping is not
  where it lives; if anything the box-only arm is the worse one.
- **Candidate 4 (different font sets) — DEAD, and the arm is valid.** Copying
  official's `/usr/share/fonts` + `fonts.conf` verbatim moved the probe's
  advance widths onto official's numbers *exactly* (sans-serif 245.534 →
  252.105 = official; dom span 245.547 → 252.109 = official), so the arm
  provably varied its variable ([[feedback_verify_ab_varied_the_variable]]).
  It bought 4% and left 1.47x.
- **Candidate 1 (musl mallocng instead of PartitionAlloc) — DEAD, premise was
  false.** Nothing disables PA-as-malloc on amd64 musl: the aports patch is
  `partalloc-no-tagging-**arm64**.patch`, no copium patch touches it, and no
  `use_partition_alloc_as_malloc` appears in the APKBUILD or our
  `args.gn.overlay`. Both binaries define `malloc` themselves (shim active,
  `nm -D` defined=1 / undefined=0 on both). The earlier claim in this file was
  read off a setup log and never verified ([[feedback_read_the_stored_value]]).
- Free control from the same dump: `Check failed` strings 47 (ours) vs 46
  (official) — DCHECK removal is real, not a residual.

**Still open, re-ranked:** (a) **musl string/memory routines** — no IFUNC on
alpine, so no CPU-dispatched `memcpy`/`memset`, and box layout is exactly that
kind of shuffling; (b) alpine clang vs Chromium's pinned clang; (c) the
reference is a Google build with its own PGO profile, CFI and full bundling, so
part of the residual is structural. Note `use_custom_libcxx = true` on both, so
libc++ is NOT a variable.

**How to apply:** `chromium-gap-probes.yml` is dispatch-only and takes any
`chs-fs-sha-*` artifact — re-run it before theorising further. Related:
[[project_alpine_browser_perf_vs_glibc]], [[project_runtime_perf_probe]],
[[feedback_control_excludes_one_mechanism]].

**Round 3 (runs 32505115445 / 32506057827 / 32507502333 / 32513597314) — the
no-rebuild probes are exhausted.** Also dead:

- **musl string routines.** They ARE 3-30x slower than glibc's at 64 B - 4 KB
  and ours imports all five from musl while official resolves them internally
  ([[project_chromium_musl_string_routines]]) — but LD_PRELOADing an AVX2
  implementation into our own binary moved `layout_boxonly` by **1.9%**
  (462.6 → 453.6 vs official 277.0). Lever confirmed connected: the shim was
  loaded by 6 distinct pids, so it reached the renderers.
- **libc++ hardening.** Identical assertion surface on both
  (`__libcpp_verbose_abort` x1, same source-path strings, `vector[] index out
  of bounds` absent on both). `use_custom_libcxx` fixes the mode too.
- **Orderfile / CFI.** Neither binary has `.text.hot` or `.text.unlikely`, so
  no section-prefix splitting on either side; CFI symbols 0 on both. `.text` is
  151,895,539 B ours vs 161,907,689 B official (1.066x) — official is BIGGER,
  which tracks our feature cuts (webrtc/dawn/xnnpack) rather than optimization.

**The partition that survived everything.** Sorting kernels by what executes
them: compiled Blink C++ (`layout_boxonly` 1.60-1.67x, `dom_churn` 1.67x) vs
V8 heap (`js_alloc` 1.16x) vs JIT-emitted machine code (`int_math` 1.00x,
`libm_fmod` 1.00x, `typed_array_*` 1.01x). Everything the C++ compiler
produced is ~1.6x; everything emitted at runtime is at parity.

**What is left, all needing a build:** PGO+ThinLTO TOGETHER (never run; each
alone went 1.42 → 1.28 / 1.31), and alpine clang **22** against official's
clang **23.0.0**. No cheap probe remains — the next step costs ~40 h and is
jean's call.

**Round 4 — PGO+ThinLTO landed the gap at 12%, and static inspection is now
exhausted** (build 32530923539, compare 32650654039, probe 32665276324):

| arm | geomean | layout |
|---|---|---|
| baseline | 1.42 | 2.27 |
| PGO | 1.28 | 1.89 |
| ThinLTO | 1.31 | 1.89 |
| **both** | **1.12** | **1.61** |

Also dead:
- **TLS.** Both binaries: `__tls_get_addr` undefined ×1, and ZERO relocations
  in all six TLS classes. Not a broken probe — `is_component_build = false`,
  so Blink lives in the main executable and every `thread_local` is local-exec
  on both sides. I ranked this first without checking the build shape; the
  hypothesis is sound for a shared-library layout and inapplicable here.
- **Under-inlining.** ThinLTO GREW our `.text` 151,895,539 -> 165,909,030
  (+9.2%), landing 1.02x ABOVE official's 161,907,689. Smaller `.rodata`
  (0.89x) and `.bss` (0.58x) track the features we cut (webrtc/dawn/xnnpack).

**What is left can only be seen at runtime:** alpine clang 22 vs official's
23 (instruction selection/scheduling, invisible in section sizes), and
musl-vs-glibc beyond the routines already excluded — futex/pthread contention,
scheduler. Our binary carries no producer string, so the clang version comes
from aports' `_llvmver`, not the artifact.

**Next instrument should be `perf record` of the layout kernel inside both
containers**, not another static candidate. Seven eliminations in, elimination
is clearly the slow path; a profile names the cause instead.

**Round 5 — the clang candidate is one-sided and not testable.** Checked
2026-08-24, no build:

- Official IS clang **23.0.0**, read from the artifact
  (`readelf -p .comment`, run 32665276324). Ours printed NOTHING there: the
  finalize strip drops non-alloc sections, so our own pipeline erases the
  producer string. "clang 22" comes from aports' `_llvmver=22`, a recipe, not
  the binary — the two halves are not the same kind of fact. Fix with
  `--keep-section=.comment` or read an unstripped round image.
- **Alpine edge has no clang 23** (`apk search clang2*-dev` → 20, 21, 22). The
  clean one-variable A/B — same musl, same args, bump `_llvmver` — cannot be
  run. It needs LLVM 23 built for musl first, and a self-built LLVM against
  Alpine's patched llvm22 is no longer a single variable.
- Effect size argues against it regardless: a clang major moving ONE metric
  61% would be extraordinary ([[feedback_match_instrument_to_effect_size]]).
  Cheap bound: compile a layout-shaped kernel under clang 21 vs 22 and see how
  little an adjacent major buys.

So the two survivors are not equally actionable. The **libc control**
(same clang, same args, glibc base) costs the same ~38 h and separates musl
from the whole compiler family at once, which the unbuildable clang A/B
cannot. And `perf record` still beats both: same symbols each slower =
codegen, time in malloc/futex/syscalls = libc.

PGO is NOT a suspect — it demonstrably engaged (1.42 -> 1.28 alone), via
`pgo_data_path` from the public profile download.

**Allocator and linker: source-level confirmation (2026-09-09, ~10 min of
`curl`, no build).** Both were already settled on the artifact by
[[project_chromium_launch_dso_closure]]'s `nm -D` census; this adds *why*, so
neither has to be re-measured:

- **PartitionAlloc.** `build_overrides/partition_alloc.gni` at `151.0.7922.34`
  gates `use_allocator_shim_default` on sanitizers, Fuchsia, Windows-debug,
  component-Windows and Cronet only — there is **no musl carve-out** in it or in
  `base/allocator/partition_allocator/partition_alloc.gni`. aports' APKBUILD
  sets no PA gn arg, and `cr149-musl-alloc-shim-dispatch.patch` — whose name
  reads like it disables the shim, and which `chromium-gap-probes.yml`'s header
  cited as evidence that aports "patches PartitionAlloc-as-malloc OUT for
  musl" — is a **three-line test disable** (`if (is_win || is_linux && false)`
  around `base_unittests`' `SystemAllocatorTest`). PA-as-malloc is on in both
  arms by upstream default. The header comment fix landed as PR #213
  (2026-09-11).
- **We do not build with mold.** aports sets `use_mold=true`, which would be a
  real code-layout divergence from official's lld — but `apply-and-build.sh`
  does **not** source aports' `gn_config` at all. Our `args.gn` is
  `args.gn.overlay` plus a few injected lines, and the overlay pins
  `use_lld = true`. Any reasoning that starts "aports sets X" has to check the
  overlay first: the APKBUILD supplies patches and `_llvmver`, not gn args.

**Round 6 — `perf record` finally ran, and it names one symbol** (run
**34406201201**, `chromium residual-gap probes`, artifact
`chromium-perf-record`). This is the instrument Round 4 asked for.

Controls are clean: both legs report the same `tag checksum=1679700`, both
profiled a 30 s window inside the same 100 s loop, and total event counts match
(3.236e10 official / 3.196e10 alpine).

| leg | iterations | median | top DSO | libc share |
|---|---|---|---|---|
| official | 369 | 258.8 ms | `chrome-headless-shell` 95.75% | `libc.so.6` **2.54%** |
| alpine | 282 | 340.5 ms | `chrome-headless-shell.real` 91.43% | `ld-musl-x86_64.so.1` **6.47%** |

**`memset` alone is 6.30% of all alpine samples — the hottest symbol in the
profile by 5x** (next is 1.19%). Official's entire libc is 2.54% and its top
libc symbol is 0.79%. Per iteration that is ~7.1e6 event-units in `memset`
against ~2.2e6 for official's whole libc, i.e. roughly **20-25% of the
layout_boxonly gap sits in this one symbol**.

Not a volume difference: neither side sets `init_stack_vars`, and both are
`is_official_build = true`, so both zero-init stack vars identically. glibc
IFUNCs `memset` to `__memset_avx2_unaligned_erms`; musl's is a scalar loop with
no ERMS and no CPU dispatch.

**Unresolved tension, do not skip it.** Round 3 LD_PRELOADed an AVX2 shim and
got only **1.9%** on this same kernel. Either the hot `memset` calls are not
reachable by preload (musl-internal callers), or
`playwright/bench/fast-string-preload.c`'s `memset` is simply weak — it has a
byte-at-a-time tail and no `rep stosb` path, and it moved four routines at once
so nothing was attributable. 6.30% of samples and 1.9% end-to-end cannot both
be the whole story.

**The decisive next probe is cheap: re-dispatch the same perf-record job with a
call graph** (`--call-graph dwarf` or `fp`); this artifact recorded flat
`cpu-clock` samples only, so `memset`'s callers are not in it. Callers inside
Blink mean a preload can win; callers inside musl mean it cannot.
Do NOT re-run the 4-in-1 shim as the test — a memset-only arm with an ERMS path
is the one that separates implementation from reachability.
[[project_chromium_faststring_moves_layout_text]]

**Round 7 (2026-09-11) — the unwinder cannot name memset's callers, so count
instead.** The `--call-graph` pass (PR #209) is blind on exactly this symbol:
chromium has no frame pointers and musl's memset asm carries no CFI, so neither
`fp` nor `dwarf` walks out of it (dwarf dies at `---0xffffffffffffffff`; `fp`
recovers ONE hop, and only because memset is a leaf). Its official leg was also
empty for two control-side reasons fixed in PR #215: glibc IFUNCs to
`__memset_avx2_unaligned_erms` (exact `--symbols memset` never hits) AND
Ubuntu's libc is stripped (perf shows `libc.so.6 [.] 0x1a1bfa` without
`libc6-dbg`). The instrument that replaces unwinding: **PR #211's counting
memset preload** (`playwright/bench/memset-count-preload.c`, dispatch input
`perf_memset_count`), which answers (a) are the hot calls interposable — do
the samples move off ld-musl onto the shim's DSO — and (b) what SIZES are they.
(b) is the one that resolves the tension above: a distribution that dies below
32 bytes means glibc's win is dispatch, not store width, and no AVX2 memset was
ever going to move layout. First dispatch: run 34584573960. Early hint from the
local gate: `LD_PRELOAD=libmsc.so /bin/true` reports `calls=0`, so musl's own
startup memsets do NOT go through the preload — musl-internal callers exist and
are invisible to any shim. Also: **perf-probe shares are runner-CPU-dependent**
— the second call-graph run halved memset's share (6.30% → 3.42%) on a faster
runner; only relative facts within a run (musl libc share ≈2× official's,
memset top symbol) are stable across runs, and the "20-25% of the layout gap"
sizing above was over-confident.

**Round 6-7 chains closed (2026-09-11).** Chain D `perf/chromium-cfi-parity`
builds but SIGILLs on every launch — a CFI trap — so official's CFI handicap
is unpriced; treat the residual as a floor
([[project_chromium_cfi_parity_arm_sigills]]). Chain E
`perf/chromium-textstack-bundled` read `layout` 0.99x n.s. against the
shipped arm: bundling freetype+harfbuzz into the LTO+PGO unit does NOT move
the row, so the "text stack outside the LTO unit" candidate is dead for
layout. What both chains DID deliver is `launch` 0.79-0.81x, all of it from
the 11-library re-bundling ([[project_chromium_launch_dso_closure]]). Still
open for layout: SSP (`perf/chromium-ssp-via-clang-config`) and clang 23
(`perf/chromium-clang23`), both building, and the memset size histogram from
the counting preload (run 34619723608, post-PR #217).

**memset CLOSED (2026-09-11, runs 34619723608 / 34622651261 / 34626393552).**
Three facts, one per run. (1) Every memset in the tree is interposable: with
the counting shim through the wrapper, `ld-musl` falls to 0.1-0.2% of samples
and `libmsc.so [.] memset` takes 12-19%. (2) The renderer (read via the
shim's periodic tick, PR #219 — zygote-forked renderers announce nothing and
are SIGKILLed before any destructor) fills at a 64-127 B mode, 56% of
`layout_boxonly`'s bytes in 256-1023 B and 76% of `layout_text`'s in
256-4096 B: not the sub-32 B regime, so store width was never the exoneration.
(3) The control counted with the same shim (PR #220) has the SAME histogram
to half a percent per bucket and the same calls per iteration — boxonly
1.527M vs 1.538M (0.99x), text 5.35M vs 5.46M (0.98x). No code-path
divergence in memset usage; the retracted AVX2 shim already showed a faster
implementation moves layout nothing; and memset's share with musl's own is
3-6%. The word-loop shim itself costs both sides too much (official
layout_text +25% with it) to price glibc's memset against musl's that way.
Left for layout: SSP (`perf/chromium-ssp-via-clang-config`, +12%
instructions measured on canary loads) and clang 23 (`perf/chromium-clang23`),
both building.

**clang 23 LIVE, SSP chain lost (2026-09-13).** `perf/chromium-clang23`
finished green once alpine:edge's own clang23 package replaced the self-built
toolchain, and three `chs-perf-ab` brackets against the shipped build read
`layout` 0.96 (fast runner) / **0.87** / **0.87** (slow runner, separated),
`goto_warm` 0.94-0.99, `dom_churn` 0.92-0.98 — the first candidate to move
layout since ThinLTO, and largest where the gap is largest. Against official:
layout 1.40 (from 1.61), geomean 1.10 (from 1.12). Details and the ship path
in [[project_chromium_clang23_lever]]. The SSP-via-cfg chain (34576077869)
died at r7 on the sanitizer-header hole #223 fixed; re-run on clang23
(34763127184) it is a null control — 1.00 n.s. vs 4362396 (34931399463) —
and shipped as #245 for the sccache it gives back, not for perf.

## 2026-09-14 — PGO hit rate and compile flags, both measured (probe `chromium-build-flags-probe.yml`)

- **cc1 line is clean** (r12, clang23 branch): `-O2 -flto=thin -fwhole-program-vtables`,
  profile-use, SSP `-stack-protector 1`, no unwind tables, `-ffp-contract=off`,
  `-fsanitize=array-bounds,return` (trap — Chromium's own, not Alpine's),
  `-fstack-clash-protection` present but measured dead (10 vs 0 probe).
- **PGO profile loss**: `-Wbackend-plugin` reports "function control flow change
  detected (hash mismatch)" on ~7 % of profiled functions, 12 % of hot ones in
  blink layout (100 mismatches / 24 TUs; `BlockNode::Layout`,
  `FragmentBuilder::GetBoxType`, `CreateConstraintSpaceForChild`). Same rate in
  dom/css/platform/base → not our patches. No `unprofiled`/`out-of-date`
  warnings at all.
- **Verdict (run 34811938326)**: Chromium's exact pinned clang snapshot
  (`53d18800`, image `ghcr.io/jclaveau/chs-clang:23-g53d18800eda3-alpine-d446f00e21a1`)
  recompiling the same TUs loses 84/203/14 (layout/dom/base) against our
  100/207/18. The loss is **revision drift the official build pays too**; the
  compiler version buys ~15 hot layout fns (~2.6 % of hot). PGO loss is DEAD as
  the residual's explanation; the snapshot-toolchain chain is at most a
  compiler control, not a candidate.
- Left: runtime musl/glibc (item 4, glibc control chain, ~multi-day, awaiting
  go/no-go) and per-symbol `perf record` on the 4362396 image once its chain lands.

**How to apply:** do not re-propose "fix PGO hash mismatches" or "match
Chromium's clang for the profile"; both are measured. Probe mechanics live in
[[project_chromium_pgo_probe_mechanics]].

**Update 2026-09-16 — CFI is un-dead, as the PGO prerequisite.** The "CFI
dead" verdict above judged CFI as a codegen divergence; what it actually
changes is the PGO function hash — without it the profile drops 100% of
core/layout's counts (7% of functions). Root of the residual, see
[[project_chromium_pgo_hash_needs_cfi]].

**2026-09-16 — two candidates read against the shipped 4362396.** Flags
(`b8ae6aa`, A/B 35066041839): noise everywhere, geo 1.01~ → dead. CFI
(`5c105b1`, A/B 35066033112): layout 0.886 / goto_warm 0.95, but launch 1.24
because the resumed tree predates the DSO trim and clang 23 (44 NEEDED vs
28) — confounded, not a CFI cost. Rebased and rebuilt from scratch as
35066922165; details in [[project_chromium_pgo_hash_needs_cfi]].

**SHIPPED 2026-09-17.** The rebuilt chain 35066922165 read clean (NEEDED
28, clang 23 confirmed): geo **0.94** vs shipped, layout **0.74**, launch
1.10 (real this time, not confounded — three measured causes, all of them
CFI tax official pays too, see [[project_chromium_pgo_hash_needs_cfi]]).
Shipped via PR #260 regardless of the launch sub-gate, since the campaign's
actual bar is "better than shipped" and 0.94 clears it. This closes the
static-inspection phase of this file: the two things left are (a) the
parallel CFI+snapshot-clang chain, which fixes the residual 18 hash
mismatches CFI-on-Alpine-clang still leaves but is blocked on
[[project_chromium_snapshot_lld_stack_overflow]] and unshipped, and (b)
issue #259's hardening-removal ladder
([[project_chromium_hardening_removal_candidates]]), a different kind of
campaign entirely — removing test-irrelevant security hardening to chase
*below* official, not closing a build-quality gap. See also the Thorium
codegen-lever audit, [[project_chromium_thorium_audit]], for a third,
independent ranking of what's left (libc++ hardening, AVX2 baseline).

**CAMPAIGN CLOSED 2026-09-18 — not by anything on this list.** The launch
residual that survived every static candidate above (allocator, fonts, musl
string routines, hardening, orderfile, CFI, TLS, under-inlining, text stack,
memset, PGO/clang) turned out to sit above codegen entirely: the consumer
image paid for ICU walking 600 tzdata files against a missing
`/etc/localtime`, found by `strace -f` syscall counts, not by any profile
([[project_chromium_launch_dso_closure]]). One symlink (PR #266) closed it —
post-fix TP read (35324815014) has chromium `startup` 1.16x → ~1.05x,
geomean 1.07 → 1.05, no row left standing. Static inspection of the binary
was exhausted correctly; the gap was never in the binary. The
CFI+snapshot-clang chain and #259's hardening ladder are now further
optimization, not gap-closing.

**CFI+snapshot-clang chain (`perf/chromium-cfi-snapshot-clang`) — DEAD,
2026-09-19.** Snap chain 35291178853 finished green (20/20 conformance +
parity; linker `LLD 23.0.0` vs shipped's `23.1.1`, `.text` 5 MB smaller, same
`PT_GNU_STACK`). Two A/Bs on main (35471647046 shipped-vs-snap,
35471648695 cfi-vs-snap) both read flat: snap/cfi geo 0.98 (noise),
snap/shipped 0.94 = cfi/shipped 0.94 — identical to the ratio CFI alone
already banked. A self-built toolchain snapshot buys nothing measurable over
the shipped CFI build; not shipped, branch left for cleanup
(see [[open_user_rulings_carried_across_sessions]]).

**RESOLVED 2026-09-19 — ~1.05 was NOT all noise; CAMPAIGN REOPENED.**
`scripts/sample-cpu-models.sh` drew 18 samples (runs=10/draw) across all
four fleet CPUs against `main-6be10b3` (tz-fix commit):

| cpu | n | startup | nav | render | js | input | geo |
|---|---|---|---|---|---|---|---|
| EPYC 7763 | 5 | 1.02 | 1.09 | 1.03 | 1.01 | 1.04 | 1.04 |
| EPYC 9V74 | 6 | 1.02 | 1.09 | 1.03 | 1.01 | 1.04 | 1.04 |
| 8573C | 5 | 1.03 | 1.11 | 1.09 | 1.03 | 1.04 | 1.07 |
| 8370C | 2 | 1.01 | 1.10 | 1.16 | 1.01 | 1.04 | 1.08 |

Per-draw spread settles it kernel by kernel: **startup 0.96-1.06 is noise —
the tz fix genuinely closed it**, confirming
[[project_chromium_launch_dso_closure]]'s RESOLVED verdict stands. Three
rows do NOT wash out: **nav 1.06-1.14, real on 18/18 draws** (`goto_cold`
1.08-1.13, `goto_warm` 1.08-1.10 on every silicon — the single biggest
universal residual); **input (`click_force`) 1.02-1.06, real on 18/18**,
small; **render** is a mix — `layout` 1.11 on EPYC 7763 specifically (5/5
draws ≥1.08) vs 1.04-1.06 elsewhere, `screenshot` at parity on EPYC (1.00)
but **1.24-1.50 on Intel** (bimodal 1.00/1.16 on 8573C, the known Skia XR
highp cost, [[project_chromium_screenshot_is_skia_highp]]), `dom_churn`/
`js_alloc`/controls flat at 1.00. Per jean's ruling ("if not noise, the
goal is better or equal parity, not 1.05") the bar tightens to **≤1.00**
and static/runtime candidate hunting reopens, ranked: nav (1.09 universal),
layout (1.11, EPYC-only), input (1.04), screenshot (Intel-only).

**Instrument launched 2026-09-19 for nav — and it contradicts the old
layout theory.** New `perf stat` counter-table kernels `goto_warm`/
`goto_cold` (added to `perf-kernel.cjs` + a per-kernel counters table in
`perf-record-report.py`'s step summary, dispatched via
`chromium-gap-probes.yml`'s `run_perf_record`, PR #268 branch
`diag/perf-counters-nav-kernels`, CI run 35496062522) re-reads the
frontend-fetch finding post-CFI. First pair (`goto_warm`, dev-box,
i5, parser-validated) reads the OPPOSITE of
[[project_chromium_layout_gap_is_frontend_fetch]]'s layout numbers:

| counter | alpine | official | ratio |
|---|---|---|---|
| instructions/iter | 328M | 219M | **1.50x** |
| cycles/iter | 304M | 240M | **1.26x** |
| IPC | 1.08 | 0.91 | 1.19x |
| L1i miss/kI | 29.3 | 38.2 | 0.77x |
| iTLB miss/MI | 319 | 432 | 0.74x |
| L1d miss/kI | 11.5 | 17.6 | 0.66x |

nav runs **+50% more instructions** than official while fetching BETTER
(fewer icache/iTLB/L1d misses per instruction) — the opposite shape from
layout's frontend-fetch bottleneck. Not code-layout, so not an orderfile
candidate: something (cgroup-wide, may include the node driver process —
the CI run's per-DSO split will tell) executes more code per navigation.
`goto_cold` and `layout_reflow` counters were still running locally when
this was captured; CI run 35496062522 carries the authoritative per-DSO
table plus a PMU-availability check (Azure runners draw PMU access at
random — "unavailable" in the summary means redraw). Every future
`chromium-gap-probes` dispatch with `run_perf_record` now keeps this
counter table for free, so future builds don't need a fresh instrument to
re-check codegen shape. Read with `tally.py` on "tally"; state carried in
`$S/topdown.log` (dev-box) — PR #268 not yet merged.
