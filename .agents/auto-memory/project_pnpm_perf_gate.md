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
- First main TP run with the gate: on 543849a (543849a also fixed the wk-mixed-launch-probe.yml shellcheck lint that had redded github-context since 82751aa); result not yet recorded here.
