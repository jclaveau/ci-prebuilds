---
name: chr-static-fmod-branch-state
description: perf/chr-static-fmod (a86f9a5) makes chrome's C/C++ fmod ours by aliasing fmod inside V8's libm-fmod-custom.S; chain green 2026-10-14, finalize check fmod==v8_libm_fmod_custom at one address; 9V74 perf-gate PASS (libm_fmod 1.000x vs chs-latest, geomean 1.003; the kernel's % already rides #333), Xeon draw skipped (drew AMD), NOT promoted
metadata:
  author: Jean Claveau
  type: project
---

Branch `perf/chr-static-fmod` @ a86f9a5 (worktree `../ci-prebuilds-chrfmod`): `--alias-fmod` in `scripts/v8-libm-fmod-custom.py` adds hidden `fmod` as `.set` alias of `v8_libm_fmod_custom` inside the member V8 already pulls. Full chain run 38481289533 green (~14 h, not 36 h); Dockerfile.finalize check requires SAME ADDRESS and size (0x2cd4830, 0x421), replacing compiler_builtins' 13-byte weak stub.

Path to it: 3 failed finalizes, each a mistake in the new check, not the idea. (1) awk `END` without `\` continuation in a Dockerfile RUN = parse error line 55 → `docker buildx build --check` first. (2) finalize step sourced only versions.env; chromium version lives in derived.env → copy env lines from a finalize step that works. (3) separate gcc copy defining `fmod` in a static archive never linked (lld doesn't fetch a member only to override a weak symbol) → [[project_source_patch_reaches_build_checklist]].

**Why:** official chrome carries the same Rust fmod, so this is beyond parity; jean asked to build + measure it anyway.
**Result 2026-10-14:** 9V74 run 38552700858: ratchet libm_fmod 232 vs 232 ms (1.000x), geomean 1.003, worst goto_cold 1.031 (≈, ceiling 1.06); parity libm_fmod 0.314, geomean 0.908; PASS. Expected flat: the probe's libm_fmod is JS `%`, which #333 already routes; the alias only reaches C/C++ fmod callers, and no probe row exercises them. `want_cpus=Xeon` runs 38552733454 (drew 9V74) and 38598987804 (drew 9V45) both skipped, green with NO data (read the job log for "skipping this draw", not the conclusion). Recorded in #335. jean 2026-10-15: skip further Intel draws (flat by design); branch stays unpromoted and unmerged until asked.

**How to apply:** candidate `chs-fs-sha-a86f9a5…` vs promoted `chs-fs-sha-7837189…`, rev 1234, runs 10. Never promoted from the branch. A setup-layer edit means a full chain (resume_from skips setup, so a fix never reaches it). Chromium dispatch also needs `-f build_chromium_headless_shell_from_source=true` ([[project_gha_dispatch_once_guard]]).
