---
name: project_chromium_libc_ladder
description: the 2026-09-14 chromium ladder 4362396 -> flags arm -> libc arm — aports' compiler.patch strips official codegen flags, and how a glibc (Debian sysroot) chromium is built on an Alpine host
metadata:
  type: project
---

Two chains dispatched 2026-09-14 on top of the clang23 base (4362396,
chain 34763050768), each moving one variable:

1. **flags arm** `perf/chromium-official-codegen-flags` (b8ae6aa, run
   34891562298). aports' `compiler.patch` does more than retarget the triples
   to musl: it strips three flags upstream compiles every TU with, because
   clang22 did not know them — `-mllvm -split-threshold-for-reg-with-hint=0`
   (regalloc; crbug 40283598, LLVM's split heuristic regressed chromium so
   official pins it to 0), `-fno-lifetime-dse` (crbug 484082200) and
   `-fsanitize-ignore-for-ubsan-feature`, without which every TU sees
   `__has_feature(undefined_behavior_sanitizer)==1` under our
   `-fsanitize=array-bounds,return`. apk clang23 accepts all three (checked).
   The arm reverse-applies exactly those hunks (BUILD.gn 2+3, sanitizers.gni
   1) after aports+copium and asserts the flags are back.
2. **libc arm** `perf/chromium-glibc-sysroot` (c905428, run 34905903570;
   7cf9be3/34892706455 and 3416468/34895205665 died in setup and r1, below),
   on top of the flags arm. Official is built against a Debian sysroot on any
   host; this arm does the same on the Alpine builder: `use_sysroot=true`,
   `is_musl=false` (copium arg, only sets `_LIBCPP_HAS_MUSL_LIBC`), no
   Alpine system-lib unbundling, compiler.patch applied for its
   clang/BUILD.gn hunk only (Alpine's compiler-rt archive layout) so the
   triples stay `x86_64-unknown-linux-gnu`. Read it with
   `chs-perf-ab` `runtime_b=noble` (#240): the artifact is a glibc binary,
   staged into PW's noble image over the official binary.

**Lessons that cost iterations:**
- Chromium's sysroot is LINK-ONLY: its `ld-2.31.so` / `libc.so.6` are 4 KB
  symbol stubs that segfault at execve. The glibc-linked host tools
  (mksnapshot, torque) and the glibc-hosted rustc run on bullseye's real lib
  dirs (`COPY --from=debian:bullseye-slim`, glibc 2.31 = the sysroot's) linked
  into `/lib/x86_64-linux-gnu`, `/usr/lib/x86_64-linux-gnu`, `/lib64/ld-linux-x86-64.so.2`.
- EVERY .so in the sysroot is a stub, not only libc — and glibc's loader
  falls back to `/lib` and `/usr/lib`, Alpine's musl builds. A host tool
  whose NEEDED is missing from `/opt/glibc-rt` (wayland_scanner → libexpat)
  loads Alpine's libexpat, which drags `libc.musl-x86_64.so.1` into a
  glibc process: SIGSEGV on `--version`, r1 dead at [6285/42246] (run
  34895205665). bullseye-slim carries glibc alone; the runtime is now a
  build stage adding what the 27 host executables link beyond it (expat,
  glib, nss/nspr, uuid; enumerated from `libs =` in `host/obj/**/*.ninja`),
  and the setup shim links all of them `--no-as-needed` and asserts
  `LD_TRACE_LOADED_OBJECTS=1` names nothing outside the glibc dirs.
  Diagnosed by pulling the setup image (9.4 GB, 30 GB unpacked) and running
  `ninja host/wayland_scanner` + `ld.so --list` locally — 74 steps.
- bullseye is EOL: `deb.debian.org/debian-security` 404s on every package;
  `sed -i '/security/d' /etc/apt/sources.list`, main only.
- A `USE_SYSTEM_LIBS=()` inside an `if` is overwritten by the unconditional
  array assignment below it (run 34892706455: the unbundle harfbuzz BUILD.gn
  asked pkg-config for a .pc the sysroot has none of). Guard the whole
  assignment, not the reset.
- Alpine's clang driver appends `-lssp_nonshared` for every target; an empty
  `libssp_nonshared.a` in the sysroot satisfies it (glibc keeps
  `__stack_chk_fail_local` in libc_nonshared.a).
- rustc must be glibc-hosted or its proc-macros (gnu cdylibs) will not load:
  rustup `--default-host x86_64-unknown-linux-gnu` at Alpine's rust version
  (1.98.1), fetched as the musl `rustup-init` binary — `sh.rustup.rs` picks the
  host by `ldd` and cannot be told otherwise.
- `gh pr merge --auto` on this repo merges immediately: no required checks.

**How to apply:** read the ladder in order — flags arm vs 4362396 says what
the compiler flags buy; libc arm vs flags arm says what musl costs. A big flags
delta reopens `project_chromium_residual_gap_candidates` (its "flags clean"
verdict compared our cc1 line against expectations, not official's).
