---
name: project_chromium_screenshot_is_skia_highp
description: the chromium screenshot stage is NAMED — Skia's from_1010102_xr — and the mechanism is PINNED: every 1010102/XR op is HIGHP_ONLY by construction, so an XR surface forces the float pipeline regardless of lowp, making the raster fix a surface-format change rather than a build flag
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

**Why this matters more than the stack protector.** It is 66% of the screenshot
overrun against the protector's ~12% of the layout instruction count, and if it
turns out to be a one-line gn arg it costs a rebuild rather than a redesign.

**Related:** the surface-format reading is still open — lowp has no stages for
`1010102_xr` at all, so an XR surface would force highp *regardless* of whether
lowp is compiled. Both arms report identical display characteristics
(`colorDepth` 24, no HDR, no wide gamut) and four runtime flags moved nothing,
so if the format differs it is decided inside the build.
