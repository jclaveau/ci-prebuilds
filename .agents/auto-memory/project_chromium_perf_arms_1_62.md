---
name: chromium_perf_arms_1_62
description: the ThinLTO and PGO A/B arms for PW 1.62, cut off the sweep tip; PGO's profile ships inside the chromium tarball
metadata:
  type: project
---

`perf/chromium-thinlto-1.62` (`b689c01`) and `perf/chromium-pgo-1.62`
(`a649cb7`) branch off `feat/pw-1.62.1-sweep` @ `7ba6866` and each differ from
it by **one variable**: `use_thin_lto = true` / `chrome_pgo_phase = 2` plus the
`pgo_data_path` plumbing.

**Do not rebase the older `perf/chromium-{thinlto,pgo,official-build}`
branches.** They sit on a main from before the metrics tree, the gap probes and
six memories — `git diff main..` is ~113k deletions — and they predate the
dawn/Go fix, so they compile ~25h and then die at finalize.

Facts measured 2026-08-19 that contradict the older comments:
- The PGO profile **ships inside the chromium tarball** (`PGO profile already in
  the tree`), so the fetch path is a fallback that has never run.
- It is **296 MB** for chromium 151, not the ~83 MB the ported comment claims.
- It is a compiler input only — `.profdata` is consumed via `-fprofile-instr-use`
  and cannot reach the artifact, which is `FROM scratch` + one `COPY`.
- `is_official_build` does NOT imply LTO/PGO here: the overlay pins
  `use_thin_lto = false`, `chrome_pgo_phase = 0`, `is_cfi = false` explicitly.
  Reading the gn *default* and ignoring those three lines is how I mis-blamed a
  5h round on ThinLTO.

**How to apply:** verify each arm's resolved `args.gn` in its own setup log
before reading any number off it ([[feedback_verify_ab_varied_the_variable]]).
Different refs also mean different concurrency groups and different
`chs-build-rN-sha-*` tags, which is what lets the arms run in parallel
([[project_gha_concurrency_group_serializes_dispatches]], [[chromium_round_images_sha_keyed]]).
