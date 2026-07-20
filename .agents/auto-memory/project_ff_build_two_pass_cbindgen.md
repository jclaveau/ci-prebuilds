---
name: project_ff_build_two_pass_cbindgen
description: FF from-source build is a designed 2-pass — first ./mach build FAILS on cbindgen bare-[COUNT], auto-patches the header, retries; a mid-build Error 2 is EXPECTED, not a break
metadata:
  type: project
---

`firefox/scripts/apply-and-build.sh` runs `./mach build` TWICE by design:

1. First pass fails (`rc=2`) on the cbindgen 0.29.4 (alpine edge) bare-`[COUNT]`
   regression: `webrender_ffi_generated.h:6735: error: use of undeclared
   identifier 'COUNT'` in accessible/atk (`BudgetType_VALUES[COUNT]`).
2. Script then `sed 's/\[COUNT\]/[7]/g'` the generated header (line ~496) and
   RETRIES `./mach build`. Retry compiles clean past the accessibility dir.

**Watch-time implication:** during a FF rebuild watch, seeing `gmake: *** Error 2`
+ `END ./mach build (rc=2)` + first-pass build-clock ~22-29min is NORMAL — do NOT
call the build broken. Verify by grepping AFTER the `Patching webrender_ffi_generated.h`
marker for `error:`; empty = retry healthy. The retry runs the FULL build again, so
total FF from-source build ≈ 5-6h (2× single-pass ~2.5h), longer than you'd estimate
from one pass. Only a `error:` AFTER the patch marker (or absence of the patch marker
when `[COUNT]` is present) is a real failure. [[feedback_compaction_summary_reverify]]
[[project_ff_juggler_pageerror_musl_gap]]
