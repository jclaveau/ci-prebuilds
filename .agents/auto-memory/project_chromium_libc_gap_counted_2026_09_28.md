---
name: project_chromium_libc_gap_counted_2026_09_28
description: chromium's musl libc excess, counted locally 2026-09-28 — memcpy/memset only (~1-2% CPU per kernel), syscalls and pthread at parity, 0x698f3 is __syscall_cp_asm's ret, faststring shim inside the 3-7% null spread; no lever dispatched
metadata:
  type: project
---

Local counted compare on the i5-8350U (chromium ours vs official, then consumer vs
consumer+`libfaststring.so` with a null repeat), all per loop iteration.

**Chrome-side libc CPU (cpu-clock, ms/iter, ours/official):**

| kernel | memcpy | memset | cmp/str | pthread | other (syscalls) |
|---|---|---|---|---|---|
| goto_warm | 0.97/0.56 | 1.50/1.05 | 0.30/0.30 | 0.78/0.98 | 1.47/1.83 |
| goto_cold | 2.14/1.40 | 2.39/2.20 | 1.83/1.57 | 1.81/2.50 | 3.73/4.24 |
| screenshot | 3.06/2.52 | 1.27/0.98 | 0 | 0/0.13 | 0.33/0.15 |
| layout_text | 2.61/2.22 | 108/76 | 0 | 0 | 0 |

- musl's unresolved `0x698f3` hotspot is the `ret` after `syscall` in
  `__syscall_cp_asm`, i.e. glibc's `epoll_wait`/`read`/`write` rows. It is not compute.
- The `node` MainThread's libmimalloc/musl share is the Playwright client, not
  chrome, and it inflates eval_rtt/locator_click's libc column.
- locator_click: browser syscalls are at parity (352,779 vs 362,964 per 15 s;
  musl makes fewer futex calls). Page faults 0.54x. Instructions 1.028 and
  task-clock 1.023 on a rerun, so the first run's 1.18 cycles was turbo drift.

**Microbench, ns per call, one pinned core:**
- memset: musl (`rep stosq`) = glibc = `rep stosb` at ≥2 KB. musl is 2x at ≤512 B.
- memcpy: musl is 2.1-2.5x at 2-8 KB and 1.4x at 64 KB-1 MB. `rep movsb` closes
  it up to 1 MB. At ≥4 MB glibc uses non-temporal stores and wins 2x.
- faststring's AVX2 memset is WORSE than musl at ≥64 KB (1.3x at 1 MB, 1.9x at 16 MB).

**faststring shim, interleaved alpine/shim/alpine2 (medians ms):** goto_warm
36.30/36.62/37.34, goto_cold 75.66/77.33/78.33. The null spread is 3-7%, and the
expected libc gain is 1-2%. layout_text moved -4.3% but memset's share did not
move (avx2_set 6.40% vs musl 6.30%), so that is noise. An earlier +10% on
goto_warm came from a run 50 minutes after its control. Third strike after
PR #201 and PR #306 [[project_chromium_faststring_moves_layout_text]].

**Why:** memset sizes and counts already match official
[[project_chromium_residual_gap_candidates]], so what is left is per-call speed
on small memsets and mid-size memcpys, about 1-2% of a kernel.

**How to apply:** do not reopen a libc/string preload for chromium. A `rep movsb`
memcpy for 2 KB-1 MB is the only untested shape; ship it only if a null-bracketed
A/B resolves below 2%. Local A/B runs are too noisy for that, so it needs n≥3.
