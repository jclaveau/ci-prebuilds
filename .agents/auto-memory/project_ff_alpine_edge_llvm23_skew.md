---
name: project_ff_alpine_edge_llvm23_skew
description: Alpine edge moved compiler-rt/wasi-sdk/wasi-compiler-rt/wasi-libcxx to LLVM 23 while aports' firefox still pins clang22 — breaks EVERY cold firefox build (wasm builtins, then PGO's runtime, then a latent wasi-libc++ header gap); fixed by following the runtimes instead of the pin (PR #298)
metadata:
  type: project
---

Alpine edge did a wholesale LLVM bump: `compiler-rt`, `wasi-sdk`,
`wasi-compiler-rt`, `wasi-libcxx` all now track edge's DEFAULT llvm, which is
**23**. `community/firefox`'s aports still pin `_llvmver=22`
(`apply-and-build.sh` reads this from `$APORTS/APKBUILD` at build time). A
clang with no matching runtime still *installs* and *compiles* fine — the
skew only surfaces at link time, under whichever flag actually needs a
runtime. Three faces, found in this order across four failed dispatches:

1. **wasm builtins** — `wasm-ld: error: cannot open
   /usr/lib/llvm22/lib/clang/22/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a`.
   Builtins are plain wasm32 objects, so cross-version symlinking the wasi
   target dirs (`clang-22 -print-resource-dir`'s `lib/` ← glob the newest
   `/usr/lib/llvm*/lib/clang/*/lib/wasi`) plus the wasm target `.cfg` files
   works, proven by compiling a real C and C++ wasm TU in the same layer.
2. **PGO's instrumentation runtime** — `libclang_rt.profile.a` missing too,
   because `/usr/lib/llvm22/lib/clang/22/lib` **does not exist at all**:
   clang22 on edge is a bare compiler with zero runtimes, not just missing
   the wasm slice. Symlinking is dead here: llvm22's `llvm-profdata` refuses
   to merge a profraw written by the 23 runtime ("PLEASE update this tool to
   version in the raw profile"). See [[project_ff_pgo_arm_mechanics]].
3. **wasi libc++'s `_LIBCPP_HAS_FILESYSTEM 0`** — a *latent*, unrelated bug
   the fix exposed rather than caused: for the wasm target, `<fstream>`
   collapses to forward declarations in `<__fwd/ios.h>`, so bundled
   hunspell's `csutil.hxx:128` (`std::ios_base::openmode`) fails with
   "incomplete type" even though the file already includes `<fstream>`.
   `<ios>` still carries the real class. **clang22 and clang23 fail
   identically** — proven by measurement before guessing (first assumed
   `<ios>` wouldn't help since `<fstream>` was already there; it does help).
   Never reached before because the fake-cdm link error (item 2) killed the
   same parallel `make` batch seconds earlier every previous attempt.

**Fix (PR #298): follow the runtimes, not the pin.** `apply-and-build.sh`
now checks `clang-$LLVMVER -print-resource-dir` for a `lib/` subdir; if
aports' pin owns no runtime, it falls forward to the newest installed llvm
that does (`llvm_owns_runtimes()`), fails loud only if none do. This is a
no-op the day aports catches up, self-heals for the next skew, and **deletes
the need for the wasi shim entirely** once firefox moves onto clang23 (clang23
owns its own compiler-rt/wasi natively — verified full PGO roundtrip:
generate link → profraw → `llvm-profdata merge` → `-fprofile-use` compile,
all OK). `apply-and-build-iter.sh` mirrors the same selection so an iter
build can't relink a base against a different toolchain than built it.

**Confirmed end-to-end, 2026-09-23.** The clang23 branch this fix targets
(`firefox/clang23-arm`, sha `3fe2571`, run 35831067833) finished
`build-firefox` **success** at ~4h01 — longer than the ~2h48 clang22 cold
reference, expected since a freshly-resolved `apk` layer has no warm object
cache to reuse. clang23 + hunspell `<ios>` fix holds under a real cold
build, not just the roundtrip check PR #298 already verified. Same run's
`perf-gate-firefox` then **PASSED**: parity `sha-3fe2571` vs official on
EPYC 7763 geomean **0.910**, every row ✅ (`libm_fmod 0.628`, `dom_churn
0.738`, `goto_warm 0.869`, worst row `click_force 1.000`); ratchet vs
`ff-latest` **0.999**. **PR #298 merged → `7f89233`.** `firefox/pgo-arm`
rebased onto it (4 commits `2a85f07 55e10c9 e50c1c0 56d0a9c`), the wasi shim
(`4a4ab04`) dropped from the branch — see [[project_ff_pgo_arm_mechanics]]
for the PGO redispatch this unblocked.

**How to apply:** any cold firefox build failing at link time with a missing
`libclang_rt.*` or a wasm/wasi toolchain error — check `clang-$LLVMVER
-print-resource-dir` for a `lib/` subdir before assuming it's a code bug.
`patchset-hash.sh` reseeds the base image on every `firefox/scripts/*` edit
(except `apply-and-build-iter.sh`), which is *why* this skew only surfaced
now — the PGO script change forced a cold build against today's edge instead
of reusing an already-passing prebuilt base.
