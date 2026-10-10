---
name: project_chromium_nav_input_local_levers_2026_10_01
description: 3 local nav/input levers counted 2026-10-01 — font .ttf swap, mremap/fcntl callers, locator_click node split — all DEAD; goto_cold instructions 0.98x official
metadata:
  type: project
---
Queue `tmp/queue-nav-input.sh`, 2026-10-01 23:08Z–00:05Z, two runs, PERF_STRACE_STACKS=mremap,fcntl.
Outputs: `tmp/counted-shipped-vs-official/`, `tmp/counted-ttf-vs-official/`.

- **Font swap (.otf → official's FreeSans.ttf, image `alpine-dood-playwright:ttf`)**: DEAD for nav.
  The variable did vary (layout_text checksum 3774184 = official's, shipped 3837212).
  goto_cold insn vs official 0.98 in both runs; our own arm .ttf 370M vs .otf 358M (cross-run, no gain).
- **mremap**: 100% musl `pthread_getattr_np` main-thread stack probe — one ENOMEM mremap per page,
  140 per new process (3 pids × 140 in a goto_cold window). Official 0 (glibc reads /proc/self/maps).
  ~µs each → well under 1 ms per process. Not a lever.
- **fcntl**: musl `fopen`/`fdopen` adding F_SETFD/F_GETFL; counts swing with the 5 s window
  (goto_warm ours 8 vs official 282). Not a lever.
- **locator_click**: wall 1.00x, CPU 1.01x this run. chrome insn 1512.5 vs 1512.4. node+JIT 478 vs 484 M.
  Only delta: allocator — ld-musl 126 + mimalloc 67 vs libc 134 + libstdc++ 10 (+49 M/iter, ~2% CPU).
  Consumer's global `LD_PRELOAD=/usr/lib/libmimalloc.so.2` → `libmimalloc-secure`; `-insecure` ships beside it.
  **Counted 2026-10-05 23:20-23:35Z** (`CANDIDATE_LD_PRELOAD=/usr/lib/libmimalloc-insecure.so.2`, chs-latest both arms,
  `tmp/counted-night-node-mimalloc-insecure/`; the chromium launcher unsets LD_PRELOAD, so node only):
  eval_rtt wall 297 vs 318 ms (0.93x), CPU 0.96x, insn 694 vs 713 M (0.97x); locator_click wall 1.00x, insn 0.97x.
  mimalloc CPU 31.9→11.9 ms/iter (eval_rtt). One draw; the Dockerfile.alpine:488 comment chose -secure on a
  CI A/B (33066499518) reading ~2%. jean 2026-10-06: ship it, security parked in requested-memory parked_node_driver_mimalloc_insecure_security.

**Caveat:** counters are system-wide; official arm disturbed in goto_cold (run 1) and goto_warm (run 2) —
read instructions, not task-clock, on those rows.

**How to apply:** don't re-run these three. Nav residual is not syscalls or font; see [[project_chromium_residual_gap_candidates]].
