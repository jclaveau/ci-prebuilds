---
name: project_pnpm_perf_gate
description: pnpm-perf-gate (TP) gates promote on an offline vitest install, cgroup CPU-ms, candidate vs promoted alpine-dood-pnpm; margins from a null pair; parity vs ubuntu report-only (standing 1.03-1.06x)
metadata:
  type: project
---

Shipped 2026-10-29: f331934 (report-only), 3d29298 (ratchet HARD, in promote's needs).

- Script: node/bench/pnpm-install-probe.sh, arms `name=image|binary` (`image` = the image's own pnpm). Gate JSON in `$OUT/gate`, rows install_cpu/install_sys/install_user.
- assert-perf-gate.py `--rule ratchet|parity|all`, `pnpm` section in perf-gate-margins.json.
- Null pair (pnpm-install-probe.yml mode=null_pair, same image both arms, n=10, runs 40964388778 + 40965002901, 9V74/9V45x2/7763x3): worst cpu 0.964, sys 0.959, user 1.026, geomean 0.968. install_user cv up to 0.045, so margin 0.07; others 0.05.
- Parity alpine/ubuntu on 12.16.1: cpu 1.031-1.059, sys 1.013-1.038, user 1.069-1.151 — a real gap, not noise; parity step stays continue-on-error.
- First main TP run with the gate: 40966546721 on 543849a (8573C), PASS. Ratchet install_cpu 2456 vs 2462 ms (0.997), sys 1528 vs 1528 (1.000), user 926 vs 938 (0.987). Parity vs ubuntu install_cpu 2456 vs 2239 ms (1.097), sys 1.035, user 926 vs 766 (1.209), report-only. 543849a also fixed the wk-mixed-launch-probe.yml shellcheck lint that had redded github-context since 82751aa.

## The 12.x statx regression: 12.7.0 -> 12.8.0, filed as pnpm/pnpm#17500

- pnpm-install-probe.yml `mode=versions` (5e5b796): one arm per version x libc on the ubuntu image, STRACE_ROUNDS, STRACE_PATH_ARMS path trace summarised by node/bench/pnpm-stat-paths.py.
- Sweep 40967650816 (8573C, every release 12.6.0-12.16.1, glibc): statx 53,184 (12.6.0), 53,904 (12.7.0), then 121,020-121,311 from 12.8.0 on. Single step.
- Adjacent pair 40970514010 (n=10 installs + 5 strace passes, 12.8.0 vs 12.7.0, glibc): statx 120,939 vs 53,887 (2.24x) on every CPU; sys 1,874 vs 1,634 ms (1.15x) 9V74, 2,334 vs 2,029 (1.15x) 7763, 1,306 vs 1,160 (1.13x) 8573C; user 1.01-1.05x. musl moves the same (via `stat`, 114,604 vs 47,577).
- Path trace: +66,898 symlink-following statx on store blobs = one per linked file (67,068). Paths stat'ed twice 421 -> 36,405.
- Suspected commit (code reading, the only behavioural change to deps-restorer/src/link_file.rs in the range): a90ec21a2 "fix(store): materialize imported files at the current umask (#15646)" adds `source_has_desired_mode` = `fs::metadata(source)` before every `hard_link`; still on pnpm main 2026-10-30. Not a dup of #16677/#16678 (umask 0000 copies).
