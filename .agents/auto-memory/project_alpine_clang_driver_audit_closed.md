---
name: alpine_clang_driver_audit_closed
description: The full cc1 audit of Alpine's clang22 driver — it injects SSP 2, stack-clash-protection and _FORTIFY_SOURCE=2, and only SSP costs anything; also proves the SSP parity flag changes codegen, not just the -### line
metadata:
  type: project
---

`clang++ -###` on Alpine edge's `clang22` (22.1.8) shows exactly three hardening
additions the command line never asked for, from aports' own driver patches
(`30-Enable-stack-protector-by-default-for-Alpine-Linux.patch`,
`clang-001/002-fortify-*.patch`, `-DCLANG_DEFAULT_PIE_ON_LINUX=ON`):

    -stack-protector 2
    -fstack-clash-protection
    -internal-externc-isystem /usr/include/fortify   (+ #define _FORTIFY_SOURCE 2)

Measured on the artifact, **two of the three cost nothing**:

- `-fstack-clash-protection` emits a per-page probe loop only for frames >= one
  page. On a realistic C++ TU (`<string> <vector> <map> <sstream> <regex>`) it
  emits **zero** probes and `.text` is **byte-identical** with and without it.
  Real, overridable with `-fno-stack-clash-protection`, and worth nothing.
- `_FORTIFY_SOURCE` is predefined as 2, but **no `__*_chk` symbol is emitted at
  all** — in C++ *or* C, on a TU written to trigger it (fixed-size struct
  fields, runtime length, `strcpy`, `snprintf`). The include path is there; the
  wrappers do not fire. Not a cost and not a lever.

The SSP one is the whole tax, and the audit also settles how to control it:

    default (= 2)                    guard-refs 3
    -fstack-protector                guard-refs 3   <- INERT, swallowed by the driver
    -Xclang -stack-protector -Xclang 1  guard-refs 0
    -fno-stack-protector             guard-refs 0

on functions strong guards but level 1 does not (an escaping scalar, no char
array). So the parity flag changes **codegen**, not merely the `-###` line —
`-###` shows cc1 receiving `"-stack-protector" "2" "-stack-protector" "1"` and
last wins. And chromium's own `build/config/compiler/BUILD.gn` applies plain
`-fstack-protector` on POSIX-non-Apple, so level 1 is exactly official's
posture, confirmed from their source rather than inferred.

**Why:** the CfT chain diff ([[project_chromium_cft_build_chain_diff]]) left the
compiler as one of two live candidates, and "what else is the driver injecting"
was the cheap half of it. It is now answered: nothing else that costs.

**How to apply:** do not open a stack-clash or FORTIFY candidate. The compiler
side of the chromium gap is fully accounted for by the SSP-parity chain already
running plus the clang 22-vs-23 residual, which
[[project_chromium_cft_build_chain_diff]] parks as too expensive to test.
The `-mframe-pointer=none` seen in the bare `-###` dump is NOT a divergence:
`build/config/compiler/compiler.gni` resolves `enable_frame_pointers = true` for
`is_apple || is_linux`, so official Chrome on Linux x64 builds WITH frame
pointers, and gn hands the same `-fno-omit-frame-pointer` to our build — the
bare-driver default is overridden on both sides. Worth one prologue census
(`push %rbp` counts on the two artifacts) next time the gap-probe workflow runs,
since it has both binaries in hand and this was settled by reading gn rather
than by looking at what shipped.
