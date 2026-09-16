---
name: project_chromium_cfi_parity_arm_sigills
description: the CFI chromium arm's launch SIGILL is RESOLVED — one cfi-icall type mismatch, sqlite's aSyscall ioctl cast (glibc `unsigned long` vs musl `int`), folded by clang into a ud1 in setDeviceCharacteristics so the first sql::Database::Open trapped; fixed by musl-source-fixes.sh on perf/chromium-cfi-pgo (chain 35039005875 resumed from the arm's r12); also: running the .real binary inside perf-alpine inherits LD_PRELOAD=mimalloc and dies in PartitionAlloc's free — a harness artefact, not the bug
metadata:
  type: project
---

**The CFI-parity arm is unrunnable, not unbuildable.** Run 34387189058
(`perf/chromium-cfi-parity` @ `d9b38d0`, `is_cfi = true` +
`use_cfi_icall = true` on top of PGO+ThinLTO) built green — the old overlay
comment said alpine clang lacks IFUNC support and the arm would die at link;
it did not. Conformance then went 20/20 shards red with the same signature on
all 358 launches: `browserType.launch: Target page, context or browser has
been closed` and `<process did exit: exitCode=null, signal=SIGILL>` right
after the dbus/vaapi/Floss warnings, i.e. inside browser-process startup.
SIGILL with no crash report is `-fsanitize=cfi` in trap mode (`ud2`), so the
binary trips a CFI check on its own startup path under musl. The control leg
(mcr noble, official binary) passed 20/20 in the same run, so it is the arm,
not the harness.

**Why:** the arm's purpose was to price the handicap official carries (Chrome
for Testing has both flags on by default for linux x64 official builds); a
binary that cannot launch prices nothing. Which check fires is unknown —
`cfi-icall` into musl-resolved function pointers and cross-DSO vcall on the
libc++ we bundle are both plausible, and trap mode discards the type.

**How to apply:**
- Do not re-dispatch `perf/chromium-cfi-parity` as is; a perf read is
  impossible. The only next step is a diagnostic rebuild with
  `use_cfi_diag = true` (prints the violated type instead of trapping,
  ~38h build), and only if pricing the handicap is still worth a build slot.
- The residual-gap accounting stands as measured: our ratios are against an
  arm that pays CFI, so the true codegen deficit is >= the residual. Say
  "at least" when quoting 1.12 / 1.61, not "equal to".
- CFI stays dead as a perf candidate (it was already ruled out as a
  divergence explaining the gap, [[project_chromium_residual_gap_candidates]]);
  this closes chain D of round 6-7.

**Update 2026-09-16 — the framing above is backwards.** CFI is not a
handicap official pays: with `is_cfi=false` Google's PGO profile hash
mismatches on exactly the hot functions, so our build runs them without
counts (no inlining, no CG-sort edges). See
[[project_chromium_pgo_hash_needs_cfi]]. The SIGILL is therefore a blocker to
fix, not a curiosity: symbolised relink of this arm's r12 image + gdb on the
box to name the trap site, then an `ignores.txt` entry.

**Update 2026-09-16 — RESOLVED, one trap.** Reproduced on the box through a
real Playwright launch (`--dump-dom about:blank` does NOT trip it; PW's arg
set with `--user-data-dir` does): `Thread "ThreadPoolForeg" SIGILL` at
`unixDeviceCharacteristics+15` = `ud1 0x2(%eax)` (ubsantrap kind 2 =
CFICheckFail), called from `sqlite3BtreeOpen` ← `sql::Database::Open` ←
`content::BtmDatabase::Init`. The whole `sectorSize==0` branch of sqlite's
`setDeviceCharacteristics` is the trap: `osIoctl` casts `aSyscall[28]` to
`int(*)(int, unsigned long, ...)` (glibc's prototype) while musl declares
`int ioctl(int, int, ...)`, and with the callee statically known clang folds
the cfi-icall type test to false. sqlite already carries the `int` signature
under `__ANDROID__` (bionic); `scripts/musl-source-fixes.sh` takes that
branch on every non-glibc libc, run at setup and before every ninja so a
resumed chain compiles it in. The other 27 aSyscall casts match musl. No
`ignores.txt` entry needed. Chain: `perf/chromium-cfi-pgo` b355c2a, run
35039005875, `resume_from` the arm's r12 image (sqlite3.o + relink only).

**Harness trap on the way there:** `perf-alpine:local` sets
`LD_PRELOAD=/usr/lib/libmimalloc.so.2`; the PW wrapper script `unset`s it
but running `chrome-headless-shell.real` (or the fs artifact's bare binary)
directly inherits it. mimalloc then owns `strdup`/`realpath` (the shim never
defined them) while the executable's `free` is PartitionAlloc's, so
fontconfig's `FcStrFree` dies in `FreeInUnknownRoot` with `int3; ud2`
(SIGTRAP, rc 133) before any CFI code runs. Not a CFI trap, not a bug —
`unset LD_PRELOAD` first, and read `ud1` (CFI) vs `int3; ud2`
(IMMEDIATE_CRASH) before naming the killer.
