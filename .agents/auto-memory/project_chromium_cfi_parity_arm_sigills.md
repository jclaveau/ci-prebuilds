---
name: project_chromium_cfi_parity_arm_sigills
description: the CFI-parity chromium arm (is_cfi + use_cfi_icall, perf/chromium-cfi-parity d9b38d0) links and builds but every launch dies with SIGILL — a CFI trap — so official's CFI handicap cannot be priced without a use_cfi_diag rebuild; the old "no IFUNC on alpine clang" comment was wrong about WHERE it fails
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
