---
name: project_alpine_node_gap_is_apk_build_config
description: issue #350's alpine-dood node slowdown is mostly apk's nodejs build (code cache off + 10 shared libs), then musl malloc in pnpm-gyp (no mimalloc), then coreutils multicall linking libcrypto; musl's own share ~+8 ms/node start
metadata:
  type: project
---

Measured 2026-10-29 (local i5-8350U, CPU-ms, 3 interleaved rounds), posted on #350.
Libc control = unofficial-builds `linux-x64-musl` node 24.22.1 tarball in the same alpine image.

- apk `nodejs-24.22.1-r0`: `node_use_node_code_cache=false` + shared zlib/openssl/simdutf/…
  `node -e 0` 82 vs ubuntu 44 ms; tarball musl 52. require-all-builtins 248 / 113 / 131. gzip 427 / 295 / 327.
- `alpine-dood-pnpm-gyp` has NO mimalloc preload (playwright images do): `Buffer.alloc(~70KB)` churn 8659 vs 3234 ms; mimalloc → 3140. Preload taxes +12 ms per node boot.
- alpine `/bin/true` = GNU coreutils multicall linking libcrypto/acl/attr/utmps/skarnet: 2.85 vs 1.34 ms/exec; plain dynamic exec is FASTER on musl (0.89 vs 1.26 ms).
- Codecov step uses `cli.codecov.io/latest/alpine/codecov`, a different binary — not our node.

Contradicts the old "node boot 0.18 vs 0.20 s" line in [[project_alpine_browser_perf_vs_glibc]] for apk node.

**Ruling (jean, 2026-10-29):** node must be optimized same-or-better than ubuntu's — file a bug + propose a CI design with a parity bench like the browser builds (perf-gate). Unofficial tarball OR our own build both acceptable. Filed as #351 (stage A unofficial-builds tarball w/ pinned sha since SHASUMS unsigned; stage B own clang23 LTO+PGO build w/ static mimalloc; node-perf-gate arms candidate/promoted/ubuntu/official, n=10).

Coreutils (#350 cause 3): GNU 9.11 split binaries each link only musl: 1000 execs true 2700→856, cat 2827→958, ls 3127→1138 CPU-ms; but `--without-openssl` makes sha256sum 50 MB 0.198→0.479 s — keep openssl for the *sum tools. First build failed silently (missing linux-headers) — check build exit before trusting /opt/cu numbers.

**How to apply:** for alpine node perf, check `process.config.variables` first; fix candidates (unofficial-builds node, pnpm-gyp mimalloc, coreutils) each need jean's go. Planner-side PATH-swap confirmation was proposed, not run.

**Go (jean, 2026-10-29, on #351):** (1) stage A only now — unofficial-builds tarball (sha-pinned `node/node-musl-sha256.txt`, `scripts/pin-node-musl-sha.sh`) to settle the whole CI pipeline; custom builds later. (2) align node with the browsers: `LD_PRELOAD` mimalloc-insecure, then ensure it is faster on the Planner workload. (3) split GNU coreutils per reco. Edits uncommitted in node/Dockerfile.alpine, alpine-gha-tools, ubuntu-gha-tools; bench ubuntu vs alpine-old vs alpine-new was running; node-perf-gate + renovate + playwright + README follow-ups pending.

**Planner bench (2026-10-29, 5 interleaved rounds, CPU-s, Planner ci/alpine-prebuilt-images a733bc0a, --cpus=4):** ubuntu vs apk-node vs tarball vs tarball+mimalloc: install 84.0 / 106.5 / 106.3 / 97.9; vite build 29.2 / 38.2 / 38.5 / 33.8; vitest 14.3 / 18.1 / 17.2 / 15.6; 20x node -e 0 0.81 / 1.47 / 1.06 / 1.01. Container-wide preload wins every step → kept as ENV. Residual vs ubuntu 1.09-1.25x = startup (boot_e0 1.16x, require_builtins 1.16x in node-perf-kernel) → stage B territory. pnpm install sys-time gap (37 vs 28 s): ATTRIBUTED, see below.

**pnpm install sys gap = the pnpm binary the Planner pins, not the image (2026-10-29):** pnpm 12 is a Rust binary. `packageManager: pnpm@12.6.0` makes the image's pnpm run 12.6.0, which on alpine is the static musl build (`@pnpm/exe.linux-x64-musl`). It has no embedded mimalloc, which pnpm only embeds from 12.16.0 (bisected: 12.6.0-12.15.0 have none). It also ignores the image's LD_PRELOAD mimalloc because it is static, so it runs on musl mallocng. Laptop, Planner tree, strace -ff, the pnpm process alone, ubuntu vs alpine: futex 7,425 vs 453,884, mmap 933 vs 45,742, munmap 360 vs 43,015; linkat equal. CI probe `.github/workflows/pnpm-install-probe.yml` (run 40960645048, vitest da7ce17 fixture, 67k files, 3 runners: EPYC 7763 / 9V74 / 9V45), sys median, each arm vs ubuntu-glibc-12.6.0:
- alpine-musl-12.6.0: 3.60 vs 1.97 / 3.35 vs 1.66 / 2.52 vs 1.50 s (1.83x / 2.02x / 1.67x)
- ubuntu-musl-12.6.0: 1.88x / 2.11x / 1.73x, so the binary carries the gap, not the image
- alpine-musl-12.16.1: 2.37 vs 2.32 / 1.90 vs 1.91 / 1.88 vs 1.77 s vs ubuntu-glibc-12.16.1, i.e. parity; futex 240k → 3k
- user follows the same shape (1.92-2.24x → 1.12-1.17x)

Re-run 40961643910 (9V74, 7763 ×2) gives the same: 1.76-2.11x → 1.17-1.22x. perf stat, cgroup: context switches 107-138k vs 15-18k, task-clock 4.8-5.4 vs 2.2-2.9 s (old musl vs old glibc). The shape holds on every CPU. 12.16.1 itself costs +15-17% sys over glibc 12.6.0 (statx 53k → 121k). Fix: the Planner bumps `packageManager` to pnpm ≥12.16.0, or drops the pin. Not shipped; it is jean's call, in the Planner repo.

**node-perf-kernel gotcha:** `require('<npm dir>')` throws (npm has no programmatic API since v8); require lib/npm.js + lib/commands/install.js + @npmcli/arborist (~540 modules).

**Gotcha:** busybox `find` has no `-lname`, so a dangling-symlink check passed vacuously — validate a check by feeding it a known-bad case.
