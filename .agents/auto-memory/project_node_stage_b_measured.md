---
name: project_node_stage_b_measured
description: #351 Stage B SHIPPED e9994e6 (2026-10-31) in node/Dockerfile.alpine; clang23 ThinLTO+PGO node geomean 0.880x vs ubuntu on EPYC 7763, 0.898x on 9V74 (gzip_20MB 1.07x vs Stage A there); build gotchas — 6 h job limit, local mi_malloc, libatomic at run time
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

Shipped e9994e6, promoted by Test and Publish run 41200859767 (2026-10-31). The
plain node runs under the image's mimalloc LD_PRELOAD; libatomic is installed.
On EPYC 9V74 (Zen 4): geomean 0.904x vs Stage A, 0.898x vs ubuntu, startup at
parity, but gzip_20MB 92.4 vs 86.4 ms (1.07x) vs Stage A: clang's bundled zlib
is slower there only (the 7763 reads 0.99x). node-perf-gate is report-only, so
it went red without blocking the promote.

**How to apply:** the pin is NODE_MUSL_IMAGE (tag + digest) in node/Dockerfile.alpine.
A NODE_VERSION bump fails the build with "NODE_MUSL_IMAGE holds node X, not Y":
dispatch node-musl.yml on the bump branch (a multi-hour cold build), then pin the new tag.
Or build with NODE_BUILD=tarball, which test-and-publish passes automatically when
the node_version input is set. node/musl-build/** + node-musl.yml are in
test-and-publish paths-ignore. In node-musl's bench, b_plain reds the gate by design
(the control arm). The zlib row: see below.

**gzip_20MB gap = fortify memcpy check (2026-11-01, node-zlib-profile.yml).**
Deflate only: 9V74 1.09-1.11x, 9V45 1.24-1.26x, 7763 0.97-0.99x vs Stage A.
Hot loop = insert_string in deflate_slow; Alpine clang predefines
_FORTIFY_SOURCE=2, so fortify-headers wraps the 4-byte hash memcpy in an
overlap compare + ud2 (4877 ud2 vs gcc node's 589). Ruled out: crc32 SIMD
(both arms table crc32_z), PGO (counts present). Lever `-U_FORTIFY_SOURCE` in
build-node.sh (7763022), cold build run 41354850829; NOT repinned (jean's call).
Hosted runners here had no PMU: profile with `perf record -e cpu-clock`;
`perf report` needs `--no-inline -g none -f` or prints nothing (addr2line).
Same lesson as chromium: [[project_chromium_nav_gap_is_musl_fortify_overlap_check]].

**Xeon 8370C (jean 2026-11-01): passive.** No dispatch to hunt an 8370C draw. When a
node-perf-gate or node-musl bench job lands on one, put its Stage B line in #335.
