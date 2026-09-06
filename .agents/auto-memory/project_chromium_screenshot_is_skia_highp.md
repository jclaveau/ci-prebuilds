---
name: project_chromium_screenshot_is_skia_highp
description: the chromium screenshot cost is Skia's extended-range 10-bit decodes — dominated by from_10101010_xr (7.43%), whose int64->float AVX2 has to emulate per lane, NOT from_1010102_xr (1.74%); every 1010102/XR op is HIGHP_ONLY by construction, so the fix is the surface format, not a build flag
metadata:
  type: project
---

Follows [[project_chromium_perf_record_first_read]], which put 66% of the
screenshot overrun in an unnamed Skia raster-pipeline float family. It is named
now, and without building anything.

**The stage is `from_1010102_xr`.** Skia's `src/opts/SkRasterPipeline_opts.h`
around line 2045 carries the exact constants the disassembly showed:

```
// i.e. "float = (xr10_value - 384) / 510.0f", ...
*r = (cast((rgba      ) & 0x3ff) - 384.f) * (1/510.f);
*g = (cast((rgba >> 10) & 0x3ff) - 384.f) * (1/510.f);
*b = (cast((rgba >> 20) & 0x3ff) - 384.f) * (1/510.f);
```

Mask `0x3ff` at bits 0/10/20, bias −384, divide by 510 — the extended-range
(XR) 10-bit decode. The second hot region is its store side
(`store_10101010_xr`, `to_unorm(scale=510, bias=384)`), which is why it works
in 16-bit lanes with `vpminuw`/`vpcmpeqw`. **Grepping upstream source for a
constant beat every attempt to reason about the pixel format** — 2 minutes
against a day of relocation tables and byte matching.

**Skia states the failure mode outright.** Same file, the lowp namespace:

```
#if defined(SKRP_CPU_SCALAR) || defined(SK_ENABLE_OPTIMIZE_SIZE) || \
        defined(SK_DISABLE_LOWP_RASTER_PIPELINE)
    // Having nullptr for every stage will cause SkRasterPipeline to always
    // use the highp stages.
```

That is exactly the observed shape: the same stage functions present in both
binaries, ours entered far more often.

**Measured on both SHIPPED artifacts** (run 33085387835). lowp is 16-lane
8/16-bit code whose `div255`/`scale` helpers lower to `vpmulhrsw`, rare
elsewhere:

| instruction | ours | official | |
|---|---|---|---|
| `vpmulhrsw` | **380** | **4371** | **11.5x fewer** |
| `vpmaddubsw` | 2392 | 4252 | 1.8x |
| `vpavgw` | 202 | 478 | 2.4x |
| `vpackuswb` | 899 | 1777 | 2.0x |

**PINNED 2026-08-27, and it is NOT the lowp gate.** `SK_RASTER_PIPELINE_OPS_LOWP`
in `src/core/SkRasterPipelineOpList.h` contains **zero** 1010102 or XR ops;
every one of them lives in `SK_RASTER_PIPELINE_OPS_HIGHP_ONLY` (line 162):

```
M(load_1010102)       M(load_1010102_dst)    M(store_1010102)     M(gather_1010102)
M(load_1010102_xr)    M(load_1010102_xr_dst) M(store_1010102_xr)  M(gather_1010102_xr)
M(load_10x6)          ...
M(gather_10101010_xr) M(load_10101010_xr)    M(load_10101010_xr_dst) M(store_10101010_xr)
```

So **an XR surface forces the float pipeline by construction**, whether or not
lowp is compiled — there is no lowp implementation to fall back to. The gating
`#if` and the 11.5x `vpmulhrsw` deficit are real observations but they are NOT
the mechanism for the screenshot gap, and the earlier "which of the three
defines" question is the wrong question.

**Therefore the raster fix is a SURFACE-FORMAT change, not a build flag.** It
cannot ride a cflags chain; what has to be found is why our screenshot path
hands Skia an extended-range 10-bit surface where official's does not. Both
arms report identical display characteristics (`colorDepth` 24, no HDR, no wide
gamut) and `--force-color-profile=srgb`, `--disable-gpu`,
`--disable-gpu-compositing` and `--use-gl=swiftshader` all left it unmoved, so
it is decided inside the build rather than by the environment or a runtime flag.

The per-opcode ratios being non-uniform (11.5x, 1.8x, 2.4x, 2.0x) is consistent
with this: a wholly-nulled lowp would read near zero, and what we are looking at
is probably a different count of compiled SkOpts ISA variants — interesting, but
a separate question from the screenshot.

Ruled out as the source of the lowp thinness (a separate, still-open
question):
- **aports** — its chromium APKBUILD mentions no `optimize_for_size`, no skia
  patch, no lowp flag.
- **our `args.gn.overlay`** — sets none of them, and the composed args.gn is
  echoed in the setup log of any from-source run if you want to check a
  specific build.
- **`SKRP_CPU_SCALAR`** — chosen from `SK_CPU_X64_LEVEL`, which is ≥ SSE2 on
  every x86-64 target, so scalar is unreachable here.

**CORRECTION 2026-08-28 — the dominant stage is `from_10101010_xr`, not
`from_1010102_xr`, and a 64 KiB bucket is not a function.** The dispatch table
gives real function boundaries; attributing the CI samples to them instead of to
buckets moves the answer:

| stage | share of our screenshot CPU |
|---|---|
| `0x535ba60`..`0x535bf20` — **`from_10101010_xr`** (64-bit, 10x6) | **7.43%** |
| `0x535bf20`..`0x535c090` — its store side | 2.34% |
| `0x535b900`..`0x535ba60` — `from_1010102_xr` (32-bit) | **1.74%** |
| `0x535b800`..`0x535b900` | 0.39% |

I named the stage the byte pattern matched and then read the whole 64 KiB
bucket's 18.24% as if it were that one function. It was not: the table says the
function at `0x535b900` ENDS at `0x535ba60`, and most of the hot addresses were
past it. **Anchor to the dispatch table before attributing samples to a name.**

Identified the same way, on the artifact: `vpsrlq $0x6` on 64-bit lanes with a
qword mask of `0x00000000000003ff` (read out of `.rodata`), matching Skia's
`from_10101010_xr` — `(cast64((_10x6 >> (n+6)) & 0x3ff) - 384.f) * (1/510.f)`.

**And this is WHY that stage is the expensive one.** AVX2 has no int64→float
instruction (`vcvtqq2ps` is AVX-512DQ), so Skia's `cast64` is emulated one lane
at a time — the disassembly shows `vpextrq` / `vmovq` / `vextracti128` feeding
four separate `vcvtsi2ss` per vector. The 32-bit sibling converts a whole vector
at once, which is exactly why it costs 1.74% where this costs 7.43%.

**The family conclusion is unchanged and better supported.** Both hot stages are
extended-range 10-bit decodes, both are HIGHP_ONLY, and together with the store
they are ~11.9% of our screenshot CPU. The lever is still the surface format;
only the name of the stage that dominates was wrong.

**CORRECTION 2 — the 66% was CANVAS-ONLY, and the flag that removes it is not
shippable.** Measured on the campaign's real page (`screenshot_png_text`, 800
rows of antialiased text), flags applied to the alpine arm only, XR share read
within each arm so it survives the runner-CPU dependence:

| arm | XR stage share of our CPU | CPU ratio vs control |
|---|---|---|
| baseline | 4.78% | 1.36x |
| `--disable-gpu-compositing` alone | 4.57% | 1.32x |
| `--disable-gpu` + compositing | **0.00%** | **1.28x** |

Three things fall out, and two of them are corrections to me:

- **`--disable-gpu` is the flag that kills the XR path**, not
  `--disable-gpu-compositing` — the narrower one leaves the share untouched
  (4.57 vs 4.78). Runs 33120353729 and 33121027568; both provably applied, the
  probe records `browser_args` in its JSON, and sample volumes are comparable
  (26-31e9 event-ns, 109-162 symbol rows) so `0.00%` is an absence rather than
  a resolution floor.
- **The XR family is ~17% of the main-binary delta on the real page, not 66%.**
  The 66% came from the flat-canvas control, which has no text and therefore
  over-weights the pixel-conversion path enormously. A control chosen to make
  bytes comparable is not automatically a control that apportions cost. Read
  cost on the kernel that matches the metric.
- **So the whole XR lead is worth ~6% of the screenshot ratio** (1.36 -> 1.28),
  and buying it costs `--disable-gpu`, which this repo already knows breaks
  WebGL: `args.gn.overlay` records that a build without Vulkan-backed rendering
  made chromium report "Initialization of all (0) EGL display types failed" and
  fail `capabilities.spec.ts::should support webgl(2)`. We do not control
  consumers' launch args either, so shipping it means baking it into a launch
  wrapper for everyone.

**Verdict: real, cheap to test, and a dead end for shipping.** It is a runtime
flag rather than a build change — which was the question — but the answer does
not change the chromium plan, because the flag is one nobody can ship and the
prize is ~6% rather than the two thirds the canvas control implied.

**Why this matters more than the stack protector.** It is 66% of the screenshot
overrun against the protector's ~12% of the layout instruction count, and if it
turns out to be a one-line gn arg it costs a rebuild rather than a redesign.

**Related:** the surface-format reading is still open — lowp has no stages for
`1010102_xr` at all, so an XR surface would force highp *regardless* of whether
lowp is compiled. Both arms report identical display characteristics
(`colorDepth` 24, no HDR, no wide gamut) and four runtime flags moved nothing,
so if the format differs it is decided inside the build.
