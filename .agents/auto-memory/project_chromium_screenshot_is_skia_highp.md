---
name: project_chromium_screenshot_is_skia_highp
description: the chromium screenshot stage is NAMED — Skia's from_1010102_xr highp raster-pipeline stage — and our artifact carries 11.5x fewer of lowp's signature instructions than official's, which is what forces every raster op into the float path
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

**What is established and what is not.** Established: the stage's identity, and
that our binary carries far less of lowp's characteristic code. NOT yet
established: *which* of the three defines does it, or whether it is a define at
all rather than a smaller set of compiled SkOpts ISA variants — the per-opcode
ratios (11.5x, 1.8x, 2.4x, 2.0x) are not uniform, and a wholly-nulled lowp
would read closer to zero than 380. Do not write "lowp is disabled" into a
commit until that is pinned.

Ruled out as the source so far:
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
