---
name: project_chromium_pgo_hash_needs_cfi
description: the chromium PGO profile only applies to hot Blink functions when CFI is ON — with is_cfi=false the CFG hash mismatches on the virtual/indirect-call-heavy (= hot) functions, 7% of functions but 100% of the counts in core/layout; six hot TUs go 330 -> 18 mismatches with -fsanitize=cfi-vcall,cfi-icall; fortify/bounds/hardening/compiler/revision are NOT it; this is the root of the two-band layout, the iTLB 2.3x and the +13% instructions; blocker is the CFI arm's launch SIGILL
metadata:
  type: project
---

**Finding (2026-09-16, issue #249 item 2, run 35032505434).** Google's
`chrome-linux-<branch>.profdata` is collected from an official build with
`is_cfi = true` + `use_cfi_icall = true` (Linux x64 defaults in
`build/config/sanitizers/sanitizers.gni`). CFI's type tests are branches in
the IR that the IR-PGO function hash covers, so a build without CFI computes a
different hash for every function with a virtual or indirect call — precisely
the hot layout/style/DOM functions. clang drops their counts ("function
control flow change detected (hash mismatch)").

Six hot TUs recompiled per variant (functions mismatched / counts dropped):
base 330 / 437 M; `-U_FORTIFY_SOURCE` 332; `-fno-sanitize=array-bounds,return`
330; libc++ hardening off 348; **`-fsanitize=cfi-vcall -fsanitize=cfi-icall
-fsanitize-trap=cfi -fsanitize-ignorelist=../../tools/cfi/ignores.txt` 18 /
115 M**. Run 34811938326 had already shown the shape (core/layout: 7% of
profiled functions, 100.3% of counts) but called it revision drift; it is not
(`block_node.cc` is byte-identical at the profile's revision a3fcbad and the
tag) and Chromium's own clang mismatched the same way — the variable was our
`is_cfi = false`.

**Why it matters — it is the residual's mechanism:** no counts → no hot-path
inlining (+13% instructions on layout) and no `.llvm.call_graph_profile`
edges, so lld's cdsort leaves those functions in input order (the second hot
band at `.text+120–131 MiB`, iTLB misses 2.3×, 243 vs 154 hot pages). The
orderfile relink (run 35029967863) confirmed the direction cheaply: layout
0.95, iTLB 0.61×, but L1i flat — hotness order is not call-graph order.

**Blocker:** the CFI-parity arm builds but SIGILLs on launch
([[project_chromium_cfi_parity_arm_sigills]]); `use_cfi_diag` forces `-O1
-fno-inline`, unusable for perf. Find the trap site with a symbolised relink
of its r12 image (`chs-build-r12-sha-d9b38d0…`, run 35035503088) under gdb on
the box, ignorelist it, then a CFI chain.

**How to apply:** treat `is_cfi` as a PGO prerequisite, not a hardening
option; when an arm changes anything that alters the IR CFG (sanitizers,
hardening, CFI), check the hash-mismatch census first — `probes/link-census.sh`
prints it per dir. Correct the "at least 1.12" framing in
[[project_chromium_cfi_parity_arm_sigills]] and the CFI-dead verdict in
[[project_chromium_residual_gap_candidates]].
[[project_chromium_layout_gap_is_frontend_fetch]] [[project_chromium_pgo_probe_mechanics]]
