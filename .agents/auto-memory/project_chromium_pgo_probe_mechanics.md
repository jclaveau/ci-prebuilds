---
name: project_chromium_pgo_probe_mechanics
description: how to recompile chromium TUs inside a round image and read PGO hash-mismatch warnings — gn object paths, IR-profile listing format, busybox traps, the false-zero lesson
metadata:
  type: project
---

Lessons from `probes/build-flags-probe.sh` (PRs #229, #230, #238), which reruns
single TUs from `out/headless` inside a `chs-build-rN` image.

- **gn object naming**: `obj/<BUILD.gn dir>/<target>/<basename>.o`. Every blink
  core TU lands in `obj/third_party/blink/renderer/core/core/` (element.o in
  `core_hot/`) whatever its source subdir; `obj/base/base/values.o`. Look objects
  up by source path, walking the dir up, and exclude `*test*`/`*fuzzer*` targets
  — `ninja -t targets all` lists unittest targets that were never built.
- **Keep the full cc1 line**: `eval "$line -###" | grep '"-cc1"'`; a driver
  default `-stack-protector 2` sits after the explicit `1`, first wins.
- **Warnings**: `-Wprofile-instr-unprofiled -Wprofile-instr-out-of-date
  -Wbackend-plugin`; the loss shows as "function control flow change detected
  (hash mismatch) NAME Hash = H up to N count discarded".
- **Denominator**: IR-instrumented profiles have NO "Function count" line in
  `llvm-profdata show --all-functions`; pass `--counts` and take the max of
  `Block counts: [...]` (= the warning's "up to N"). Intersect with
  `llvm-nm --defined-only` of the dir's objects.
- **Round image is busybox**: no `join` (use awk NR==FNR); `sort`/`awk` fine;
  capture stderr or errors vanish.
- **False zero**: run 34808672663 reported 0 mismatches from EMPTY logs (the
  alt pass read a TU list that did not exist). Assert `grep -c '^###'` per log
  and make an empty log an ERROR row before believing any zero
  ([[feedback_verify_ab_varied_the_variable]]).
- **Dispatch**: `gh workflow run chromium-build-flags-probe.yml --ref main
  -f script_ref=<branch> [-f alt_clang_image=<img>]` — scripts come from any
  branch, only the workflow file needs main. ~35 min, ~80 with the alt pass.

**How to apply:** reuse the script for any per-TU recompile question (flag
A/B, another compiler) instead of a new chain; the verdict itself is in
[[project_chromium_residual_gap_candidates]].
