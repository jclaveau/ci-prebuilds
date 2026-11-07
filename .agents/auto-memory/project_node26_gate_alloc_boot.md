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

**mimalloc options** (round 4 run 42330744004, round 5 run 42333710198 with arm order rotated):
- alloc_buffers: none closes it. PURGE_DELAY=-1 a few % at best, EAGER_COMMIT / ALLOW_LARGE_OS_PAGES nothing, PURGE_DELAY=0 3.4-5.0x dearer.
- boot_e0: `MIMALLOC_ALLOW_LARGE_OS_PAGES=1` cuts 2-7% (7763 1.085x→1.013x, 9V45 1.026x→0.995x vs official), faults/spawn unchanged; host THP `madvise`. SHIPPED f998075 (run 42341824830, 9V74 gate boot_e0 1.013x vs ubuntu, alloc 0.98x); RSS cost unmeasured.
- all 12 kernel rows without vs with it: spawn_true_x100 0.57-0.66x everywhere, boot_e0 0.91-0.98x, rest 0.99-1.02x; geomean 0.953x. Mechanism = parent fork copies fewer PTEs (2 MiB pages), so child faults don't move.
- Intel i3-4005U (Haswell, Debian kernel 6.12, maison-titateur): the option is a NO-OP, THP `always` geomean 1.003x, `madvise` 0.993x, spawn 0.998-1.021x; AnonHugePages identical off/on (32768 kB). So "win everywhere" holds only on GHA's AMD runners; why AMD gains is open. RSS cost none: peak 487 vs 485 / 386 vs 402 MiB (ranges overlap), boot maxRSS 53 vs 53 MiB. Official glibc node's spawn doubles under `madvise` vs `always` (349 → 944 ms).
- a fixed arm order biases the first arm: rotate it per round.

**How to apply:** don't chase our build for these rows. alloc_buffers = accept or per-row ceiling; boot_e0 lever ALLOW_LARGE_OS_PAGES is shipped; gate json_roundtrip is bimodal (26 or 36 ms per shot on both arms), a breach there is noise. See [[node-stage-b-measured]], [[alpine-node-gap-is-apk-build-config]].
