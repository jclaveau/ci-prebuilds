---
name: project_chromium_residual_gap_candidates
description: our chromium sits ~1.3x official even with PGO or ThinLTO — three probes ran, candidates 1/2/4 are dead, the residual is in box layout
metadata:
  type: project
---

After either perf knob, alpine chromium is still ~1.28-1.31x official on geomean
and 1.89x on layout ([[project_chromium_perf_arms_1_62]]). Run
**32502670597** (`chromium-gap-probes.yml`, all arms on one runner) killed three
of the five candidates.

**Measured** (`chromium-gap-probe.cjs`, 800 children, 300 forced reflows, ms):

| kernel | official | pgo | pgo+noble fonts |
|---|---|---|---|
| `layout_boxonly` | 299.4 | 471.4 (**1.57x**) | 463.0 (1.55x) |
| `layout_text` | 763.8 | 1170.1 (**1.53x**) | 1122.9 (1.47x) |

- **Candidate 2 (unbundled fontconfig/freetype/harfbuzz) — DEAD.** The gap is
  *fully present* on a subtree with no text node in it. Text shaping is not
  where it lives; if anything the box-only arm is the worse one.
- **Candidate 4 (different font sets) — DEAD, and the arm is valid.** Copying
  official's `/usr/share/fonts` + `fonts.conf` verbatim moved the probe's
  advance widths onto official's numbers *exactly* (sans-serif 245.534 →
  252.105 = official; dom span 245.547 → 252.109 = official), so the arm
  provably varied its variable ([[feedback_verify_ab_varied_the_variable]]).
  It bought 4% and left 1.47x.
- **Candidate 1 (musl mallocng instead of PartitionAlloc) — DEAD, premise was
  false.** Nothing disables PA-as-malloc on amd64 musl: the aports patch is
  `partalloc-no-tagging-**arm64**.patch`, no copium patch touches it, and no
  `use_partition_alloc_as_malloc` appears in the APKBUILD or our
  `args.gn.overlay`. Both binaries define `malloc` themselves (shim active,
  `nm -D` defined=1 / undefined=0 on both). The earlier claim in this file was
  read off a setup log and never verified ([[feedback_read_the_stored_value]]).
- Free control from the same dump: `Check failed` strings 47 (ours) vs 46
  (official) — DCHECK removal is real, not a residual.

**Still open, re-ranked:** (a) **musl string/memory routines** — no IFUNC on
alpine, so no CPU-dispatched `memcpy`/`memset`, and box layout is exactly that
kind of shuffling; (b) alpine clang vs Chromium's pinned clang; (c) the
reference is a Google build with its own PGO profile, CFI and full bundling, so
part of the residual is structural. Note `use_custom_libcxx = true` on both, so
libc++ is NOT a variable.

**How to apply:** `chromium-gap-probes.yml` is dispatch-only and takes any
`chs-fs-sha-*` artifact — re-run it before theorising further. Related:
[[project_alpine_browser_perf_vs_glibc]], [[project_runtime_perf_probe]],
[[feedback_control_excludes_one_mechanism]].
