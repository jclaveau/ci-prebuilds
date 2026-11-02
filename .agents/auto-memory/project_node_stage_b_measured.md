---
name: project_node_stage_b_measured
description: #351 Stage B SHIPPED e9994e6; gzip gap = fortify, -U_FORTIFY_SOURCE candidate 5a2173715ae3 closes it on 9V74/9V45/Xeon (7763 1.05x worse, not alignment), unshipped (2026-10-31) in node/Dockerfile.alpine; clang23 ThinLTO+PGO node geomean 0.880x vs ubuntu on EPYC 7763, 0.898x on 9V74 (gzip_20MB 1.07x vs Stage A there); build gotchas — 6 h job limit, local mi_malloc, libatomic at run time
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
Fortify-off build node-musl:v24.22.1-5a2173715ae3 vs shipped Stage B, EPYC 7763
(run 41354850829): gzip_20MB 103.8 vs 100.5 ms (1.033x, noise), geomean 1.006x
(1.003x without gzip), no row over ceiling.
Deflate split (run 41394721024, candidate vs gcc A / vs shipped B): 9V74 0.95-0.96x /
0.87x, 9V45 0.99-1.00x / 0.79-0.81x, Xeon 8573C 1.02x / 0.85x, Xeon 6975P-C 0.99x /
0.81x (the Xeons had the gap too: B vs A 1.20-1.22x). Cost: 7763 deflate 1.05x vs B,
gzip_20MB 1.033x and 1.053x (2 node-musl draws, geomean 1.006/1.007). ud2: 383 vs
gcc 589 vs B 4877. Ship = jean's call (drops fortify from the whole node).
gcc does NOT fold the overlap check either (alpine:edge repro, gcc 15.2 -O2:
same compares around memcpy(&local, p, 4)); it emits jnb/jb branches and puts the
ud2 in <fn>.cold, so a ud2 count over a function body reads 0. Upstream: open
llvm#146401 + GCC PR120903 (no fix); our repro + deflate numbers commented
2026-11-02 (issuecomment-6572881734).
Loop placement ruled out (node-zlib-align run 41412540572, harness of node's zlib):
0/16/32/48-byte .text shifts and -falign-loops=32 move 7763 deflate only 0.98-1.02x,
while fortify ON vs off reads 0.97-0.99x on the 7763 (fortify faster) vs 1.21x 9V74,
1.38-1.39x 9V45, 1.21x Xeon 8573C. The 7763 loss is the code shape itself, cause open
(no PMU on hosted runners). Probe: `.github/workflows/node-zlib-align.yml`.
Hosted runners here had no PMU: profile with `perf record -e cpu-clock`;
`perf report` needs `--no-inline -g none -f` or prints nothing (addr2line).
Same lesson as chromium: [[project_chromium_nav_gap_is_musl_fortify_overlap_check]].

**Xeon 8370C (jean 2026-11-01): passive.** No dispatch to hunt an 8370C draw. When a
node-perf-gate or node-musl bench job lands on one, put its Stage B line in #335.
Fortify-kept arms (node-zlib-align run 41414276892, deflate vs pad0 = -U_FORTIFY_SOURCE):
builtin (4 sites __builtin_memcpy) 7763 0.98-1.02x, 9V74 1.00x, 6973P-C 1.05x;
headers (no overlap trap) 7763 1.00-1.03x, 9V74 1.00x, 6973P-C 1.08x; gcc zlib 7763
0.94x, 9V74 1.05x, 6973P-C 1.13x; fortify 7763 0.97-1.00x, 9V74 1.20x, 6973P-C 1.30x.
gcc inflate 0.90x on all 3 CPUs (only arm moving inflate). builtin = best keep-fortify
lever; node builds of the 3 variants: runs 41414408510/41414411079/41414413412.
