---
name: project_node_stage_b_measured
description: #351 Stage B (clang23 ThinLTO+PGO node from source, mimalloc linked in) measured geomean 0.880x vs ubuntu, 0.884x vs stage_a on EPYC 7763; build gotchas — 6 h job limit, local mi_malloc, libatomic at run time
metadata:
  type: project
---

Run 41135093907 (2026-10-30), branch `node-musl/stage-b` 91842a5, recipe tag
`v24.22.1-de4850dd5f9b`, EPYC 7763, 10 shots/arm, CPU-ms. b_mimalloc geomean
vs stage_a / ubuntu / official: 0.884 / 0.880 / 0.890. Startup rows at or
under ubuntu (boot_e0 31.6 vs 32.8 ms, require_builtins 69.2 vs 70.5 ms).
b_plain_preload within 1% of b_mimalloc, so link-in vs LD_PRELOAD is a wash.
b_plain (no mimalloc) 1.10x: alloc_buffers 702 vs 410 ms — mimalloc stays.
Full table on #351; per-CPU line in #335 (9V74/8370C not re-measured).

Build gotchas, each cost a 3-6 h run:
- Cold node compile = ~5.8 h on 4 vCPU; each PGO phase needs one run to fill
  sccache (`ACTIONS_CACHE_SERVICE_V2=1`, see [[project_sccache_ghac_readonly_v18]])
  and one to finish, under the 6 h job limit. Use `tools/install.py`, not
  `make install` (reruns `all` serially). Busybox `timeout` exits 143.
- `llvm-nm | grep -q` under pipefail = false negative (SIGPIPE): write to file.
- The mimalloc link keeps `mi_malloc` LOCAL (`t`) aliasing the exported `T malloc`;
  check same address, not a global mi_malloc.
- clang lowers node's 16-byte atomics to libcalls: needs `libatomic.so.1` at run
  time (gcc unofficial-builds node doesn't). Bench arm does `apk add libatomic`.
- Dockerfile.bench-arm is excluded from the recipe hash: bench-only fixes reuse images.

**How to apply:** switching node/Dockerfile.alpine to Stage B is jean's call;
if switched, ship libatomic (or link it statically) and add `node/musl-build/**`
+ node-musl.yml to test-and-publish paths-ignore before merging to main.
The bench job reds on b_plain's gate by design (control arm).
