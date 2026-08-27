---
name: project_wk_jit_kernels_are_at_the_floor
description: int_math at exactly 1.00 is a floor, not a gap — a JIT-only kernel runs machine code JSC emits at runtime, so it is identical on both sides by construction; four such kernels measured at or below parity
metadata:
  type: project
---

Under the strict rule (every metric must be < 1.00), `int_math` sitting at
exactly 1.00 reads as an open work item. It is not one, and the reason is
worth recording before someone spends a build on it.

`int_math` is 30M `Math.imul`/`|0` operations **inside the page**, self-timed,
after warmup. That loop runs machine code the DFG/FTL emits at runtime. Both
sides run the same JSC at the same WebKit revision, so the emitted code is the
same code — the libc, the allocator, the link-time flags and the loader are all
upstream of a boundary this kernel never crosses.

Corroborated by every other JIT-only kernel, measured side by side on one host
(ours / official, checksums identical):

```
Math.sqrt(i)              7 ms /  7 ms    inlined SSE
(i*7) % 65536             8 ms /  9 ms    int32 remainder, no libm
i * 2654435761            5 ms /  6 ms    multiply + accumulate only
int_math (probe, on CI)          1.00     30M imul/|0
```

Three of the four are already at or *below* parity. There is no residual to
recover: to push `int_math` under 1.00 you would have to make JSC emit better
code than JSC emits, which is a WebKit change, not a build-configuration one.

Treat it like `locator_click` — pinned, report it, do not chase it — but note
the pin is a DIFFERENT one. `locator_click` is frame-quantised (3333.x ms both
sides, CV 0.0%); `int_math` is pinned because the subject under test is
generated at runtime rather than built. The distinction matters: `int_math`
CAN move, and did — it read 5-9x when chromium shipped DCHECKs
([[project_chromium_dcheck_from_is_official_build]]), because that changed
which code the engine ran. So it stays in the suite as a tier/health alarm; it
just has no headroom while the tiers match ([[project_wk_allocator_and_lto_audit]]
records DFG x1513, FTL x360, CLoop x0 on both).
