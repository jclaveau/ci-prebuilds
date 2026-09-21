---
name: project_chromium_nav_gap_is_musl_fortify_overlap_check
description: the chromium goto_warm gap is Skia raster (Viz compositor + raster workers, renderer main at parity) running +50% instructions at HIGHER IPC — the code is musl fortify-headers' INLINE memcpy overlap check (two pointer-range compares + trap) emitted at every fixed-size memcpy (sk_unaligned_load/store, bit_cast) because Alpine's clang predefines _FORTIFY_SOURCE=2; glibc's fortify has no overlap check, so official never pays it; the earlier driver audit missed it by grepping for __*_chk symbols that musl's shim never emits
metadata:
  type: project
---

**Measured 2026-09-20/21 on the shipped `eb48637` (image main-6be10b3) vs
official 151.0.7922.34.**

Dev-box PMU (i5, perf-topdown, PR #268 counters table):

| kernel | wall | instr/iter | cycles/iter | IPC | L1i miss/kI | iTLB/MI |
|---|---|---|---|---|---|---|
| goto_cold | 1.00 | 1.07 | 1.01 | 1.06 | 0.97 | 0.97 |
| goto_warm | 1.14 | **1.50** | 1.26 | 1.19 | 0.77 | 0.74 |
| layout_reflow | 1.14 | 1.07 | 1.23 | 0.87 | 1.20 | 0.83 |

goto_warm is MORE instructions at BETTER fetch — the opposite shape of the
pre-CFI layout finding ([[project_chromium_layout_gap_is_frontend_fetch]]),
so not code layout, not orderfile.

**Where (CI run 35496062522, 9V74, cpu-clock, `comm-dso`):** renderer main
18.6 vs 17.9 ms/iter (parity); `VizCompositorTh` **7.45 vs 2.15** ms/iter;
`ThreadPoolForeg` (raster workers) 4.84 vs 2.91. The whole delta is the
software display compositor and tile raster. Both arms report identical
`SystemInfo.getInfo` feature status (gpu_compositing `disabled_software`,
rasterization `disabled_software`), and a viz/cc trace shows 1.0
`Display::DrawAndSwap` per navigation on both — same frames, same mode,
ours ~2x per raster task.

**Which code.** Symbolized the stripped artifact against the link census'
`symtab.nm.gz` (chain 35066922165, same `.text` vaddr/size) — perf prints
FILE OFFSETS for a stripped PIE, add `0x1000` (with the shift 0 of 46 010
samples land past a symbol's end; without it 333 do). Top of our
goto_warm main-binary CPU: `ml4::lowp::gather_8888` 7.8 %,
`ml4::lowp::matrix_translate` 5.4 %, `Sk4px::approxMulDiv255` 3.5 %,
`ml4::lowp::store_8888` 2.2 %, `seed_shader` 1.9 %, `clamp_01` 1.4 %,
`blit_mask_d32_a8_black` 1.5 % — ~22 % in the Skia lowp raster pipeline.
ISA dispatch is right (ml3 = ymm, ml4 = zmm, sse3 = xmm).

**Why.** `objdump` of `ml3::lowp::store_8888` (`0x5cdb710`): after every
vector store to a stack slot comes

```
lea 0x40(%rsp),%rax ; cmp %r9,%rax ; setb %r10b
lea 0x60(%rsp),%r8  ; cmp %r9,%r8  ; seta %r11b
test %r11b,%r10b ; jne <ud2>
cmp %rax,%r9 ; setae %r10b ; lea 0x40(%rsp),%r11 ; cmp %rax,%r11 ; setbe %bl
or %r10b,%bl ; je <ud2>
```

which is, verbatim, musl `fortify-headers` `/usr/include/fortify/string.h`:

```c
if ((__d < __s && __d + __n > __s) || (__s < __d && __s + __n > __d))
    __builtin_trap();
```

Alpine's clang driver predefines `_FORTIFY_SOURCE=2` and adds
`-internal-externc-isystem /usr/include/fortify`
([[project_alpine_clang_driver_audit_closed]]); Chromium's own
`build/config` also sets it on Linux. On glibc that resolves to
`__builtin___memcpy_chk`, which folds to a plain `memcpy` whenever the size is
a compile-time constant that fits — no overlap test exists in glibc's
fortify. On musl the shim is an inline wrapper whose overlap compares clang
does not fold even for distinct stack allocas, so every fixed-size `memcpy`
— Skia's `sk_unaligned_load`/`sk_unaligned_store`/`sk_bit_cast`, Chromium's
`bit_cast`/`UNALIGNED_LOAD`, V8's `MemCopy` — carries 10–14 extra scalar
instructions and a `ud2`. Vector-heavy raster stages are wall-to-wall such
copies, hence the +50 % instructions at high IPC and the 2x per raster
task. NOT diffuse: static `.text` insn count is 45.20 M vs official 44.96 M
(+0.5 %) and `ud2` count 269 598 vs 266 063 (CFI/CHECK traps dominate, so
`ud2` is no discriminator) — clang folds the compares at most sites; they
survive where a pointer is opaque, which is exactly the raster-stage
context pointer. Expect the lever to move raster-bound rows (nav, input,
screenshot), not layout.

**The driver audit's "FORTIFY is not a cost" was wrong**, and why: it
tested for `__*_chk` symbols, which is glibc's mechanism; musl's shim emits
NO call symbol, only inline compares and a trap. Its `-fstack-clash` and SSP
findings stand.

**Corollary:** the stale comment in `args.gn.headed.overlay` ("our build
disables FORTIFY at the compiler level via apply-and-build.sh") is false —
`grep -rn FORTIFY apply-and-build.sh` finds nothing; the shipped headless
binary carries the checks. The `__memcpy_chk trap (SkDescriptor)` crash it
mentions is this same overlap check firing on a real overlap.

**Lever — measured 2026-09-21, SHIPPED as the snapshot toolchain (PR
#273).** The `perf/chromium-cfi-snapshot-clang` build (self-built clang,
`Dockerfile.clang`, "deliberately NOT reproducing alpine's hardening driver
patches") has no fortify include path, so it IS the fortify-free build:
its `ml3::lowp::store_8888` is 0xb4 bytes / 44 insns, pure ymm + one
cfi-icall tail check, against the shipped 0x361 / 207. Five `chs-perf-ab`
draws snap-vs-cfi (eb48637) on four CPU families: geo 0.96–0.99 (5/5 < 1),
nav 0.95–0.99, layout 0.93–0.98, input ~1.00. **Smaller than the profile
predicted** (raster ≈22 % of main-binary CPU on goto_warm halved should be
≈ −8 %): the raster stages run on VizCompositorTh and raster workers, off
the renderer main thread's critical path, so −50 % raster CPU is ≈ −3 %
wall. The check is real, the lever is real, and it is one lever among
several — nav sits at ~1.06 after it, not 1.00.

The two header-level variants (patch the overlap `if` out of
`/usr/include/fortify/string.h`; `-U_FORTIFY_SOURCE`, #259 c4) were never
built: the snapshot subsumes both (also drops the object-size checks and
matches the PGO profile's compiler), so their ceiling is ≤ snap. Only worth
a chain if the packaged Alpine clang ever has to come back.

**How to apply:** when a musl build shows more instructions at higher IPC
than its glibc twin, disassemble one hot leaf and look for
`cmp/setb/seta/test/jne` pairs before a `ud2`, not for `__*_chk` symbols.
Symbolize stripped chromium via the link census `symtab.nm.gz` (+0x1000).
[[project_chromium_residual_gap_candidates]]
[[project_chromium_screenshot_is_skia_highp]]
[[project_chromium_trace_gap_is_uniform]]
