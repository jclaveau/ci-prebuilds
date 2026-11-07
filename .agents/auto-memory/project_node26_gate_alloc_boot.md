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
- all 12 kernel rows without vs with it: spawn_true_x100 0.57-0.66x everywhere, boot_e0 0.91-0.98x, rest 0.99-1.02x; geomean 0.953x. Mechanism = parent fork copies fewer PTEs (zero-page PTEs, not huge pages: next bullet), so child faults don't move.
- Intel i3-4005U (Haswell, Debian kernel 6.12, maison-titateur): the option is a NO-OP, THP `always` geomean 1.003x, `madvise` 0.993x, spawn 0.998-1.021x; AnonHugePages identical off/on (32768 kB). So "win everywhere" holds only on GHA. NOT AMD vs Intel: GHA's Xeon 8573C gains too, and NO huge pages are obtained anywhere (no hugetlb pool, AnonHugePages same off/on). Mechanism (pagemap+kpageflags, run 42376160145): on GHA kernel 7.0.0-azure with the option OFF node holds ~10-12k extra PTEs mapped to the shared ZERO page (five ~16 MiB anon mappings ~2,052 present each + mimalloc's 1 GiB arena ~2,560 vs ~480 present); fork copies / exec zaps them (copy_present_ptes, zap_present_ptes), x200 parent sys 211-243 vs 97-111 ms. Laptop 6.12: 17.1k present, 1 zero PTE, off or on. The five mappings are musl thread stacks (16 MiB+4k, mmap PROT_NONE + mprotect RW: 4 node-V8Worker + DelayedTaskScheduler), zero pages exactly on pages 0..2047 (lowest 8 MiB); arena pages 1..2047. Made AT BOOT (flat from spawn 0 to 200). Refuted as the source, each by a run: user read faults (stack/arena faults are all writes), launching under sh, THP split remap (same thp counters, try_to_map_unused_to_zeropage kprobe 0 hits), kernel-side GUP faults (handle_mm_fault callers = user path only), any extra syscall (strace -c same set, only the 2 failed MAP_HUGETLB mmaps differ). FOUND (run 42381016384, kprobes over ALL processes): a GHA host process `provjobd<pid>` reads node's memory via /proc/<pid>/mem (pread64 → access_remote_vm → get_user_pages_remote → do_anonymous_page), and the read faults map the zero pages. Per boot, off vs on: get_user_pages 8.9-16.4k vs 2.7-4.8k. So the option's GHA gain = provjobd reads less of node, NOT huge pages; it won't carry to a host without the scanner. Lesson: earlier probes filtered on node's comm and missed a foreign process faulting node's mm; filter on mm/pid target, not comm. provjobd = `/tmp/provjobd<N>` (deleted exe) under `sudo -n PROVJOBD_E2E=1` in hosted-compute-agent.service, BPF progs/maps + perf_event + pidfds (run 42381513032). It reads node's maps once, then preads the first ≤8 MiB of chosen mappings, ~64 MiB budget (run 42381892807, 4/4 runners): off = 3-4 thread stacks + arena/17.6 MiB anon + node text + 32 MiB anon (~57-65 MiB); on = SAME big two (node text, 32 MiB anon) + small libs, NO thread stacks, NO arena (~19 MiB). Cause = a RACE (runs 42382406812, 42383346818): provjobd reads a new process's maps ONCE, 4-11 ms after it starts; off, node's arena + 4 worker stacks exist by 6.6-7.4 ms and get read; on, the failed MAP_HUGETLB path delays node's thread starts to 7.2-14.3 ms, mostly after the snapshot (43 vs 59-61 mappings seen). The win is a GHA timing artefact; why the option delays thread starts is untraced. Probe history: node-hugepage-probe.yml commits e86e04f..18ee6b5, all in #335. Dockerfile.alpine's comment ("asks for transparent huge pages") states the wrong mechanism; fixing it is jean's call. RSS cost none: peak 487 vs 485 / 386 vs 402 MiB (ranges overlap), boot maxRSS 53 vs 53 MiB. Official glibc node's spawn doubles under `madvise` vs `always` (349 → 944 ms).
- a fixed arm order biases the first arm: rotate it per round.

**How to apply:** don't chase our build for these rows. alloc_buffers = accept or per-row ceiling; boot_e0 lever ALLOW_LARGE_OS_PAGES is shipped; gate json_roundtrip is bimodal (26 or 36 ms per shot on both arms), a breach there is noise. See [[node-stage-b-measured]], [[alpine-node-gap-is-apk-build-config]].
