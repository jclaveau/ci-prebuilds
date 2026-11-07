---
name: node26-gate-alloc-boot
description: Why node 26 breaches node-perf-gate on alloc_buffers and boot_e0 — mimalloc vs glibc's fast heap state, and a musl-build boot cost; NOT our build
metadata:
  type: project
---

Gate run 42308999875 (9V74): alloc_buffers ours 272 vs ubuntu 247 ms (1.10x), boot_e0 27.3 vs 25.2 (1.09x).
Probe: `node-alloc-boot-profile.yml` + `node/bench/alloc-boot-probe.cjs`; per-CPU numbers live in #335.

**alloc_buffers = the allocator, not the build** (round 3, run 42324942066):
- the kernel control reproduces it: 9V74 1.14x, 7763 1.12x, 9V45 0.93x vs official v26
- official v26 + Debian mimalloc preloaded breaches the same (1.16-1.20x)
- ours v26 beats our v24 (0.83-0.94x); official gained more v24→v26 (0.77-0.85x)
- glibc arms are BIMODAL in a probe process (official 9V74 208-348 ms, 7763 289-522) but tight in the kernel process (229-239, 285-313); mimalloc arms tight in both. Gate scores glibc's fast heap state against mimalloc's steady cost.
- a standalone probe never reproduces it, even with ballast + the gate's prelude rows: use node-perf-kernel.cjs itself as the control.

**boot_e0 = musl-build cost, CPU-dependent**: ours vs official 0.98-1.11x; gcc musl 1.15-1.24x; v24 1.03-1.10x. Preload adds ~1,070 page faults per spawn but no CPU. perf: ld-musl 8.5% + libgcc_s 6% of a boot on every musl build.

**Why:** rounds 1-2 blamed boot on the build (1.2-1.4x) — artefact: alloc rows ran before boot rows and the mimalloc heap inflated fork cost. Order rows like the gate.

**How to apply:** don't chase our build for these rows. Levers are mimalloc options (round 4, run 42330744004: PURGE_DELAY, EAGER_COMMIT, LARGE_OS_PAGES) or accepting a per-row ceiling. See [[node-stage-b-measured]], [[alpine-node-gap-is-apk-build-config]].
