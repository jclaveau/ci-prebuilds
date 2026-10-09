---
name: project_ff_pgo_arm_mechanics
description: firefox PGO SHIPPED — clang23 unblocked it (#298), generate+use both succeeded first-try on the clang23 base (3h23 + 2h41), perf-gate read geo 0.74 vs promoted 0.92 (ratchet 0.80) with controls pinned flat, merged #285 as 04dde38 and promoted; a second independent gate draw on main replicated geo 0.74 exactly
metadata:
  type: project
---

**STATUS 2026-09-23: SHIPPED.** `build-firefox-pgo-profile` (generate) ran
11:49:44→15:13:02Z (**3h23**, first ever success — died at 2h57 and 3h25
twice before), `build-firefox` (use) ran 15:13:05→17:54:11Z (**2h41**,
*shorter* than the clang23 non-PGO cold reference of 4h01 thanks to the warm
object cache from the generate pass). Both smokes and 20/20
`conformance-firefox` shards green. `perf-gate-firefox` on `sha-56d0a9c` vs
`ff-latest`, same job (EPYC 7763, n=5):

| | startup | nav | render | js | input | control | **geo** |
|---|---|---|---|---|---|---|---|
| `firefox/pgo-arm@56d0a9c` | 0.79 | 0.70 | 0.57 | 0.91 | 1.00~ | 0.86 | **0.74** |
| `fi-latest` (same job) | 0.90 | 0.92 | 0.88 | 0.97 | 1.00~ | 0.86 | 0.92 |

Ratchet vs promoted: 0.74/0.92 = **0.80** — 20% faster than what shipped,
26% faster than official glibc Firefox. `control` (`int_math`/`libm_fmod`/
`locator_click` — libc/cadence-bound, not codegen) read identically on both
arms (0.86), which is what makes the moved rows credible: PGO must not touch
controls and it didn't.

Merged **#285 → `04dde38`**. Main's own chain (`35901535046`) re-ran the
gate as an independent second draw — `startup 0.80 / nav 0.71 / render 0.58
/ js 0.89 / input 1.00~ / control 0.85 / geo 0.74`, every row within 0.02 of
the branch draw, `control` pinned 0.85–0.86 across all four arms total. Not
a runner-lottery result. Caveat: both draws landed on EPYC 7763 (same
silicon), and main's build jobs were **cache hits** (2m50/2m31 vs 3h23/2h41
on the branch — unchanged patchset hash reused the branch's image), so the
replication confirms the *gate number*, not that the build reproduces cold
from scratch. `promote-firefox` ran **success**; `ff-latest` now points at
the PGO build. (First read of this run's job list said "no promote-firefox
job" — wrong, the jobs API page-1 cap hid it on page 2 of >100 jobs; see
[[reference_gha_run_inspection_gotchas]], recurring trap.)

Everything below through "first dispatch FAILED" is the original
single-job attempt (PR #285, pre-clang23) — superseded. Skip to "Two-job
split" for the shape that shipped.

Official Playwright's firefox has no PGO (omni.ja unordered — see
[[project_ff_build_missing_pgo_lto_jemalloc]]), so a PGO arm is beyond-parity,
not a gap-closer. Mozilla quotes ~10% on JS/layout from it. Shipped as PR #285
(`firefox/pgo-arm` branch, dispatch 35619055612, cold — roughly 2x a normal
build since mach runs three stages itself).

**First dispatch (35619055612) FAILED**, 3h44 into the profile run:
```
XPCOMGlueLoad error for file .../obj/instrumented/dist/firefox/libxul.so:
Error loading shared library libmozsandbox.so: No such file or directory
```
File is present in the package — this is a loader problem, not a missing
build artifact. musl resolves a library's `NEEDED` entries only from that
library's own rpath or `LD_LIBRARY_PATH`, and Mozilla's `libxul` carries no
rpath. The shipped tree works only because `bundle-dist.sh` patchelfs
`$ORIGIN` in AFTER packaging; the PGO profile run (`profileserver.py`)
launches the **instrumented** build during the build phase, before that
patch ever runs. Fix pushed on `firefox/pgo-arm`: export `LD_LIBRARY_PATH`
to the instrumented package dir for the profile-run step. Redispatched
**35646182344** (ETA ≈ 8h from 2026-09-21 ~19:30, so ~03:30).

**Mechanics, worth keeping regardless of this arm's result:**
- `ac_add_options MOZ_PGO=1` in mozconfig.overlay is the only mozconfig change
  needed; `mach build` then does instrumented build (`obj/instrumented`,
  `MOZ_PROFILE_GENERATE=1`) → `build/pgo/profileserver.py` drives that
  firefox through Mozilla's PGO corpus → `-fprofile-use` build in `obj`.
- `mach build <target>` **refuses** with "Cannot specify targets (...) in
  MOZ_PGO=1 builds"; packaging must go through `./mach package` (plain `make
  package`, no such check) instead of `mach build package`.
- Bare `MOZ_PGO=1` (no `--enable-profile-generate/use=cross`) keeps
  `MOZ_PGO_RUST` off — needed on Alpine because rustc and clang carry
  different LLVM versions and `llvm-profdata` refuses to merge profiles
  across them.
- `profileserver.py` needs a real X display (mozrunner has no headless mode)
  — `apply-and-build.sh` starts `Xvfb :99` directly (not `xvfb-run`; alpine:
  edge only ships the bare `Xvfb` binary) and sets `MOZ_DISABLE_*_SANDBOX=1`
  for the sandboxed sub-processes under Xvfb.
- `llvm-profdata` only resolves via `clang_search_path` in configure; on
  Alpine it lives at `/usr/lib/llvm${LLVMVER}/bin/llvm-profdata`, so
  `LLVM_PROFDATA` is exported explicitly when `LLVMVER` is set.
- Disk: the instrumented objdir adds ~8-10 GB on top of the existing ~15 GB
  firefox source+obj footprint — accepted ENOSPC risk, not yet hit.
- Proof-of-execution added to the build log: `merged.profdata` size +
  `*.profraw` count under a `===== PGO profile =====` marker, so a future run
  can tell instrumentation actually happened without re-deriving it.

**Two-job split (2026-09-22).** A single `MOZ_PGO=1` `mach build` runs the
instrumented compile AND the `-fprofile-use` compile in one process — two
~3h20 builds ⇒ ~6h40, over GitHub's hard 6h `timeout-minutes` job cap. Run
35684142833 (the LD_LIBRARY_PATH-fixed dispatch above) was killed by the cap
mid `-fprofile-use`, not by a real error. Split into
`build-firefox-pgo-profile` (`PGO_STAGE=generate`) → `build-firefox`
(`PGO_STAGE=use`, `needs:` the profile job), profile handed across as a `FROM
scratch` image `:ff-pgo-profile-sha-<sha>` (Dockerfile target `pgo-profile`,
consumed via `ARG PGO_PROFILE_IMAGE`). `PGO_STAGE=generate` appends
`--enable-profile-generate`; `=use` appends `--enable-profile-use` +
`--with-pgo-profile-path=/work/pgo/merged.profdata` (+ `--with-pgo-jarlog`
when a jarlog is present) and asserts the profile file is non-empty before
compiling.

**LTO assert exemption.** moz.configure silently drops LTO for the
instrumented pass (`WARNING: Disabling LTO because --enable-profile-generate
is specified`, no `MOZ_LTO` in autoconf.mk). This repo has a hardening-arm
assert that fails loud when LTO doesn't reach configure — it now checks
`PGO_STAGE == generate` first and skips, deferring the real assert to the
`use` pass which still has to clear it.

**Root cause found 2026-09-23, after 4 failed dispatches at 4 different
guards: clang22 ships literally no compiler-rt on Alpine edge.**
`/usr/lib/llvm22/lib/clang/22/lib` does not exist — the `compiler-rt`,
`wasi-sdk`, `wasi-compiler-rt`, `wasi-libcxx` packages all track edge's
DEFAULT llvm, which moved to **23**, while aports' `community/firefox` still
pins `_llvmver=22`. Non-PGO firefox survives because Alpine's clang defaults
`--rtlib=libgcc`; only flags that need a real runtime break
(`-fprofile-generate`, the wasm sandbox's builtins — see
[[project_ff_alpine_edge_llvm23_skew]]). **Cross-version symlinking the
runtime in is dead for PGO specifically**, measured: llvm22's `llvm-profdata`
refuses a profraw written by the 23 runtime (`PLEASE update this tool to
version in the raw profile`) — a 3h instrumented build would stand a profile
that can never be merged. PGO can only compile on a clang that *owns* its
compiler-rt, i.e. clang23.

**Sequencing decision:** land the clang23 baseline first as its own isolated
arm (PR #298, no PGO) so its perf-gate number is readable on its own, THEN
rebase `firefox/pgo-arm` onto it (this also deletes the wasi shim from
[[project_ff_alpine_edge_llvm23_skew]] — clang23 needs no cross-version
symlink) and redispatch PGO on the clang23 base. Two variables in one number
would make neither reading trustworthy.

**How to apply:** if PR #285/#298 (or a rebuild of either) needs debugging,
start from this list rather than re-reading mach's PGO source or Alpine's
package graph from scratch — these are the specific traps this repo's
Alpine/musl/clang toolchain hit, not generic PGO docs. Verify via
`perf-gate.yml`/`ff-perf-ab.yml` (shipped ff artifact vs `sha-<head>`) before
merging — PGO is a beyond-parity gain, not a parity fix, so it should never
block the campaign's ≤1.00 bar.
