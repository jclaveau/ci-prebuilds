---
name: project_chromium_pgo_hash_needs_cfi
description: the chromium PGO profile only applies to hot Blink functions when CFI is ON — with is_cfi=false the CFG hash mismatches on the virtual/indirect-call-heavy (= hot) functions, 7% of functions but 100% of the counts in core/layout; six hot TUs go 330 -> 18 mismatches with -fsanitize=cfi-vcall,cfi-icall; fortify/bounds/hardening/compiler/revision are NOT it; this is the root of the two-band layout, the iTLB 2.3x and the +13% instructions; SIGILL fixed; first candidate layout 0.886 but launch 1.24 from a resumed pre-trim tree (44 NEEDED vs 28), fresh chain 35066922165
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

**Blocker — cleared 2026-09-16.** The CFI arm's SIGILL was one cfi-icall
mismatch (sqlite's ioctl cast, [[project_chromium_cfi_parity_arm_sigills]]),
fixed on `perf/chromium-cfi-pgo` (b355c2a); chain 35039005875 resumes the
arm's r12 image so only sqlite3.o recompiles. Read its conformance + a
chs-perf-ab against the shipped 4362396 before believing the census: the
CFI arm's link census (run 35035503088) still shows a `+120–130 MiB` band
(121 hot symbols vs 213) and 90% of the hot set within 75.7 MiB (was 123.5),
CG coverage 1441/2000 (was 1344) — better, not one band.

**How to apply:** treat `is_cfi` as a PGO prerequisite, not a hardening
option; when an arm changes anything that alters the IR CFG (sanitizers,
hardening, CFI), check the hash-mismatch census first — `probes/link-census.sh`
prints it per dir. Correct the "at least 1.12" framing in
[[project_chromium_cfi_parity_arm_sigills]] and the CFI-dead verdict in
[[project_chromium_residual_gap_candidates]].
[[project_chromium_layout_gap_is_frontend_fetch]] [[project_chromium_pgo_probe_mechanics]]

**Split (run 35036941795, same six TUs):** `cfi-vcall` alone fixes 310 of
the 312 (20 / 115 M left), `cfi-icall` alone fixes 1 (329 / 437 M), both 18,
`-fsanitize-cfi-icall-generalize-pointers` changes nothing. The hash lives in
the vcall type tests; icall is parity only (and the source of the sqlite
trap). The residual 18 are all in element.cc / style_adjuster.cc /
block_node.cc / block_layout_algorithm.cc — `Element::AttributeChanged` 62 M,
`RecalcOwnStyle` 19 M, `PseudoStateChanged` 10 M, `AdjustComputedStyle` 5 M,
`BlockNode::FinishLayout` 3 M — so some other official-only flag still shapes
those CFGs; a fourth variant probe is cheap (~40 min) if the CFI chain's
layout row stops short of 1.00.

**First CFI candidate read (chain 35041660126 → `5c105b1`, A/B 35066033112
vs shipped 4362396, both on one Xeon 8370C, medians candidate/shipped):**
layout **0.886** (169/191 ms), goto_warm 0.95, click_force 0.98, js_alloc
0.99; controls int_math 1.00 / libm_fmod 0.99. But launch **1.24**
(108/87 ms, 4/4 samples apart), context_page 1.05, dom_churn 1.07 → tally
geo 1.02, startup 1.14. Conformance 20/20, parity green.

**The launch loss is NOT CFI — it is the resumed tree.** The chain resumed
from the d9b38d0 arm's r12 image, whose setup ran on a branch cut BEFORE
`2f82e9e` (the DSO trim) and before clang 23 (`76df63f`); `resume_from`
skips setup, so `replace_gn_files.py`'s list and the toolchain are the
image's, only the args overlay + `musl-source-fixes.sh` come from the branch.
`readelf -d | grep -c NEEDED`: candidate **44**, shipped **28** — the 16
extra are exactly the pure-compute libs the trim re-bundles (webp/jpeg/xml2/
xslt/z/zstd/brotli/dav1d/opus/hwy/crc32c/minizip/double-conversion/
atk-bridge…), and the trim was measured at launch 0.79x. So the CFI effect on
launch is unread and the layout −11% came on top of clang 22, without the
trim.

**How to apply:** a `resume_from` candidate inherits the source image's
setup — check `NEEDED` count (28) and the clang version in the setup log
before reading any row against the shipped build; a candidate that changes
codegen for every TU recompiles everything anyway, so resume buys ~1 h of
setup and costs a confounded read. Fresh full chain 35066922165
(`eb48637` = branch rebased on main, no resume_from) is the readable one.
