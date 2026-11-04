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
fortify-builtin node vs shipped B (run 41414408510, Xeon 8370C, b_plain_preload vs
the arm named `stage_a`, which is alpine-dood-node:latest = shipped Stage B since
e9994e6, NOT gcc): gzip_20MB 83.4 vs 93.2 ms (0.895x), other rows 0.99-1.03x,
geomean 0.995x vs shipped, 0.882x vs ubuntu. 8370C has the gzip gap (shipped vs
ubuntu 1.115x); builtin closes it. Like-for-like arm = b_plain_preload (shipped
is plain node + image preload), not b_mimalloc. In #335.
Per-CPU (node-musl-bench.yml run 41467864882, builtin vs shipped gzip_20MB): 9V45
0.856-0.876x, 8573C 0.896-0.905x, 7763 1.027-1.045x; geomean 0.989-1.008 all draws.
9V74 (run 41470412645) 0.901-0.923x, geomean 0.989-0.997. node-musl-bench.yml = per-CPU bench of a built tag
vs shipped (rejection-sampled slots); use it, not node-musl.yml's single draw.
zlibonly per-CPU (run 41490523037, tag 68305fccbb40, vs shipped gzip_20MB): 9V74
0.902-0.925x (6 draws), 9V45 0.864x, 8573C 0.876x, 7763 1.048-1.057x; geomean
0.984-1.006. Same as builtin within noise, 7763 slightly worse.
zlib harness + node shape + real input (node-zlib-align run 41548404659, b61bbfc;
7763 x11, 9V74 x4, 9V45 x1, no Intel): ThinLTO+PGO pgo_fortify vs pgo_off deflate,
synthetic 7763 0.943x / 9V74 1.150x / 9V45 1.224x, node-source 20 MB 1.023x /
1.027x / 1.002x. The 7763 inversion needs PGO AND the synthetic input; on real text
fortify costs 0-3% everywhere. pgo_builtin = pgo_off (0.98-1.00x). crc32 SIMD
(CRC32_SIMD_SSE42_PCLMUL, off in node's zlib.gyp) vs fortify: inflate 0.39-0.50x
synthetic, 0.84-0.90x node-source; deflate 0.91-0.94x synthetic, ~1.00x source;
gzip total 7763 0.87x synthetic, 0.98x source. Wins on every model incl. 7763;
not built into node yet. In #335.
headers per-CPU (run 41566034181, tag d7972983a0f7, overlap trap removed from
fortify-headers, fortify kept; vs shipped gzip_20MB): 9V74 0.907-0.930x (5), 9V45
0.853-0.866x (3), 8573C 0.881-0.912x (2), 7763 1.034x (1); geomean 0.983-0.996; worst
other row spawn_true_x100 1.056x. = builtin = zlibonly within noise.
7763 top-up (run 41605035101, 6 draws): gzip 1.015-1.046x vs shipped, geomean
0.995-1.004, worst spawn 1.027x. 7763 ~1.03x on gzip confirmed.
zlib-align 41605570944: PGO trained on synthetic+real text = real deflate
0.92-0.94x on every CPU (node trains on synthetic only); crc32 SIMD inflate real
0.86x; x86-64-v3 nothing on real. Full headers+crc32+mixed PGO vs fortify real
0.93x all CPUs. Node build of that: branch node-musl/headers-crc32 (pgo-train.sh
gzips 20 MB of fixture node_modules), run 41607903538. node disabled crc32 SIMD
for nodejs/node#45268 heap corruption: run morpheus-med/node-defect repro
before trusting it. In #335.
Combined node (run 41711168972, tag v24.22.1-2cef23906fde: headers + crc32 SIMD +
PGO trained on gzip of node_modules text) vs shipped gzip_20MB: 7763 0.941x (4),
9V74 0.801x (8), 9V45 0.778x (4); 7763 regression gone; alloc rows 0.94-0.98x;
geomean 0.965-0.985 every draw; worst http_rtt 7763 1.014x. Safety gate =
node-zlib-integrity.yml (run 41711175078). Ship/repin = jean's call. In #335.
Integrity run 41711175078 (7763 x2, 9V74, 9V45): #45268 repro 40/40 rc=0 both
arms, zlib-integrity 4x3000 rounds clean both arms. No positive control (repro
never seen failing here), so a clean run bounds, not proves, crc32 SIMD safety.
Positive control (runs 41786681564, 41787218479): node 20.2.0 glibc aborts 6/43
(glibc malloc "double free or corruption"), 7763 + 9V45, 0/20 on 9V74; node
20.2.0-alpine (musl) 0/40. Repro only detects via glibc malloc checks -> blind on
musl; candidate's 40/40 clean proves nothing. crc32 SIMD safety still OPEN.
Output + canary check (run 41798460939, 4x 7763, node/bench/gzip-verify-hook.cjs
preloaded: per-stream trailer crc + round trip vs input copy, 4000 malloc'd
canaries): glibc 20.2.0 aborts 18/40 (hook raises the rate), every surviving glibc
run and musl 40/40 verify all streams and canaries clean. Damage hits only malloc
metadata -> hook FAILS its positive control; no test settles crc32 SIMD on musl.
hardened_malloc (GrapheneOS bf37d54, preloaded in place of each image's allocator,
workflow input allocator_preload): musl 20.2.0 0/40 (run 41809368317, 9V74/7763x2/9V45);
glibc node:20.3.0-bookworm-slim (20.3.0 still has crc32 SIMD; no 20.2.0 bookworm tag;
bullseye apt 404s) baseline aborts 8/40 (run 41811689477, 7763 6/30, 9V45 2/10) but
0/40 under hardened_malloc on 4x 7763 (run 41811703214): hardened_malloc HIDES the
bug -> fails its positive control. Every detector tried is blind off glibc malloc;
crc32 SIMD safety on musl cannot be tested here: ship-on-trust or drop = jean's call.

Dropping crc32 SIMD, real node build (bench 41892818867, reference_tag arm;
no-crc32 v24.22.1-5ad7a4419957 = headers + gzip PGO, branch node-musl/headers-nocrc32,
vs crc32 candidate v24.22.1-2cef23906fde): gzip_20MB no-crc32 vs crc32 7763 1.09-1.11x
(101.9 vs 92.4 ms), 9V74 1.12-1.15x, 9V45 1.13-1.19x; other rows noise; geomean
1.006-1.045. No-crc32 vs shipped gzip: 7763 1.00-1.04x (gain gone), 9V74 0.91x,
9V45 0.85-0.88x. crc32 SIMD = all of the candidate's gzip gain on the 7763.
