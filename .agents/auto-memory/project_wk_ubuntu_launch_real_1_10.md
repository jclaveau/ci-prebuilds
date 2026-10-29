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

**Root cause: Ubuntu 26.04's uutils coreutils** (not the GST registry — the ubuntu
image runs PW's OWN webkit binaries via `playwright install --with-deps`, no bake).
Loader at parity (`WPEWebProcess --version` 107.7 vs 107.4 ms, 49.3k relocs both),
file syscalls ours FEWER (2964 vs 3139 / 3 launches). pw_run.sh execs 2 uname +
2 dirname + 1 readlink per launch; uutils = one 11.8 MB Rust multicall parsing
Fluent `.ftl` locales each exec: 4.7-5.1 vs GNU 1.8-2.3 ms CPU. Local launch
CPU-ms: uutils 200.6 / gnu 186.3 / official 178.9 (1.12 / 1.04). Residual 1.04
unexplained (laptop noise or 26.04 libs: mesa 26, glib 2.88, gst 1.28, icu 78).

Fixed b12e8f0 (jean's go, 2026-10-29): `coreutils-from-gnu coreutils-from-uutils-`
+ purge `rust-coreutils`, stage flattened onto scratch (uutils is in the base
layer, a purge on top ships whiteouts): ubuntu-gha-tools 351 vs 335 MB.
Swap needs `--allow-remove-essential` AND the explicit `coreutils-from-uutils-`,
or apt keeps uutils and the A/B arm silently doesn't vary.
Side effect: node-perf-gate's ubuntu arm gets faster spawns.

**CLOSED after b12e8f0 (perf-probe 40954328312, n=10, wall ms, ours sha-b12e8f0 vs official v1.62.1-noble):**
Xeon 8573C 67.8 vs 67.65 ms (1.00), EPYC 7763 81.15 vs 82.0 ms (0.99), Xeon 8573C 60.4 vs
61.55 ms (0.98). Inline perf-report on TP 40950582503: 1.00x. The laptop's 1.04 residual
was laptop noise. Not CPU-dependent, no #335 entry.

**How to apply:** webkit/ubuntu launch sits at parity now; a red at 1.2+ is single-shot
drift — rerun once. Budget stays 1.20 (jean: fine).

Mixed-distro arm (24.04 build on 26.04, laptop 9x): laptop artifact, CI parity —
see [[project_wk_mixed_build_launch_was_laptop_artifact]].
