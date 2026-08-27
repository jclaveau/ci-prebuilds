---
name: project_chromium_use_system_libs_verdict
description: the USE_SYSTEM_LIBS trim lost half its case when perf record showed deflate at parity — it cannot reach the target on launch alone, so it rides its OWN parallel arm rather than the fix chain
metadata:
  type: project
---

The proposal was to drop the pure-compute libraries from `USE_SYSTEM_LIBS` in
`chromium-headless-shell/scripts/apply-and-build.sh` — `zlib brotli crc32c
double-conversion highway libjpeg libwebp opus dav1d zstd libxml libxslt`,
keeping `fontconfig`/`freetype`/`harfbuzz`/`libdrm` system because bundled
fontconfig uses `initstate_r`/`random_r`, absent in musl.

**It rested on two legs and `perf record` cut one off.**

- **Leg 2, the screenshot win: DEAD.** The claim was that Alpine's plain madler
  zlib lacks chromium's SIMD deflate. Measured on a GHA runner, the deflate
  region is 5.47 ms/iteration ours against 5.25 ms official — **1.04x, parity**
  — and `libz.so.1` never appears in either profile at all
  ([[project_chromium_perf_record_first_read]]). Bundling zlib buys nothing
  here. The earlier zlib-ng preload result was real but it was not measuring
  what the case needed it to measure.
- **Leg 1, `launch`, survives intact** and is still the best-evidenced single
  finding in the chromium campaign ([[project_chromium_launch_dso_closure]]):
  26.1 vs 13.9 ms per exec over 30 interleaved iterations, `DT_NEEDED` 43 vs
  28, and `ctypes.CDLL` of the 19 extra DSOs costing 11.3 ms on its own.

**But leg 1 alone cannot reach the goal.** chromium pays the closure twice per
`launch()` (browser + zygote), so ~24 ms of the 64 ms gap — a third to a half.
Perfectly executed it moves `launch` 1.61 → **~1.35-1.40, still nowhere near
<1.00**. The remaining ~40 ms is browser-process init (V8 snapshot, mojo, ICU,
`.pak`), which is the same codegen residual the stack-protector and PGO/ThinLTO
work addresses. So `launch` needs the DSO trim AND the codegen fixes; neither
alone is sufficient, which is an argument for doing it, not against.

**Verdict: not worth a 25-30 h chain of its own; worth a PARALLEL arm, never a
passenger in the fix chain.**

- As a passenger it is actively harmful: it is an unproven eleven-library
  change in the direction aports does not test — this project has already been
  burned moving libraries across that boundary (flac and ffmpeg were *removed*
  from system-libs after SONAME skew broke the runtime link). A link failure at
  hour 20 would cost the measured fixes riding with it, and any regression
  would be unattributable between the two changes.
- As its own arm it costs only runner time, which is open, and it answers
  cleanly: it either links and moves `launch` as predicted, or it does not.

**How to apply:** the edit is in the setup layer, so it is a cold r1..r12 —
audit every round's `BASE_IMAGE` first, and remember `resume_from` skips setup
so only r1 tolerates a skipped ancestor ([[project_resume_from_runs_only_r1]],
[[project_multijob_base_image_audit]]). Expect the compile graph to GROW by
eleven libraries, so budget more than the usual 25-30 h rather than less.
