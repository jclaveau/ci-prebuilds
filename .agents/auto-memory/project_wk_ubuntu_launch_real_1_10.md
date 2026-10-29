---
name: project_wk_ubuntu_launch_real_1_10
description: webkit/ubuntu launch is a REAL ~1.10x gap vs official (n=10 x 3 runners, not CPU-dependent), while webkit/alpine reads 0.80x; the 1.20 budget sits ~9% above it, so inline single-shot outliers (1.21, 1.27) trip it — not a budget to widen
metadata:
  type: project
---

perf-probe run 40908403043 (2026-10-29), `image=ubuntu-dood-playwright:latest`,
`image_b=alpine-dood-playwright:latest`, webkit, runs=10, replicates=3.
Launch median ms, ours vs official:

| runner | ubuntu-ours | alpine-ours |
|---|---|---|
| EPYC 7763 | 96.1 vs 89.2 ms (1.077) | 70.5 vs 89.2 ms (0.790) |
| EPYC 7763 | 90.1 vs 80.1 ms (1.126) | 64.5 vs 80.1 ms (0.806) |
| EPYC 9V74 | 92.1 vs 83.7 ms (1.101) | 67.0 vs 83.7 ms (0.801) |

Per-shot ubuntu/official inside one job: 1.02-1.16. Inline perf-report history at
n=1: 1.10, 1.21, 1.11, 1.27, 1.04. So the row is a ~1.10 gap plus single-shot
drift ([[project_launch_cell_drift_false_reds]]), and the 1.20 budget leaves
~9% headroom — two false reds in one day (2026-10-29).

Arm check: the `alpine` target (= `image`) JSON reports `libc: glibc`, so it
really was the ubuntu image; `alpine-b` reports musl.

Not CPU-dependent (1.08-1.13 on both models), so no #335 entry.

Untested lead: 3254ba3 fixed the alpine launch row (1.22x) by seeding the baked
GStreamer registry; whether the ubuntu variant takes the same seed path is the
first thing to check. Label: guess.

**How to apply:** a webkit/ubuntu launch red at 1.2-1.3 on a commit that ships no
webkit bytes is drift on top of the real 1.10 — rerun once. Closing the 1.10
(not widening the budget) is the fix.
