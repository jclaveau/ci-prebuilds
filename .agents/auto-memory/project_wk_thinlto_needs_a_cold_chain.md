---
name: project_wk_thinlto_needs_a_cold_chain
description: The webkit ThinLTO arm reaches the build (Dockerfile.port re-COPYs the overlay every round) but cmake configure is one-shot on CMakeCache.txt, so a RESUMED dispatch would silently ignore -DLTO_MODE=thin and hand back a flat arm
metadata:
  type: project
---

`cmake-flags.overlay` keeps `-DLTO_MODE=thin` commented out over link-step RSS
fears, while Alpine's own `community/webkit2gtk-6.0` APKBUILD turns it ON for
x86_64 alongside the clang + lld + llvm-ar we already match. This repo's
chromium arms put ThinLTO alone at geomean 1.42 -> 1.31, so it is the live
lead once the allocator one is spent ([[project_wk_mimalloc_past_bmalloc]]).

**Reach-check, both halves:**

- the overlay DOES reach the build — `Dockerfile.port` re-COPYs
  `webkit/cmake-flags.overlay` before the `RUN` that invokes
  `apply-and-build-port.sh`, on **every** round.
- but `apply-and-build-port.sh` phase 1 is
  `if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]]` — **one-shot per port**. A
  dispatch that resumes from an existing checkpoint image skips cmake
  configure entirely, the new flag never enters the cache, and the arm comes
  back having changed nothing while looking perfectly green.

So the arm must be a **cold** WPE chain (~4h: the four
`build-webkit-wpe-{1..4}` rounds were 3h53m + 4m + 4m + 4m), and the artifact
must be checked for LTO evidence before any number is read — `readelf -S`
section sizes, never md5, and never `.text` size alone (ThinLTO grew
chromium's *above* official's).

**Blocker to clear first:** `promote-webkit`'s `if` is
`github.event_name == 'workflow_dispatch' && inputs.build_webkit == 'true'` —
**any branch**. A green conformance run on an experimental LTO arm would
promote `wk-latest`, shipping an unvalidated perf build into the consumer
image and the nightly bench. Same branch-blindness already parked for chromium
in `.agents/requested-memory/parked_chromium_promote_and_pgo_comment.md`.

Also stale: the overlay's own comment justifies OFF with "same reason chromium
skips is_official_build's PGO/LTO" — chromium built those arms and they won
([[project_chromium_perf_arms_1_62]]).
