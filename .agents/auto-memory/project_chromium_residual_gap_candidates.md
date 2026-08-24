---
name: project_chromium_residual_gap_candidates
description: our chromium sits ~1.3x official even with PGO or ThinLTO — three probes ran, candidates 1/2/4 are dead, the residual is in box layout
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
