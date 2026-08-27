---
name: project_chromium_launch_dso_closure
description: chromium's launch 1.61x is the DSO closure from USE_SYSTEM_LIBS — 43 DT_NEEDED vs official's 28, 1.87x per exec paid twice per launch(); PartitionAlloc is confirmed ACTIVE on musl so there is no firefox-shaped allocator win
metadata:
  type: project
---

Measured 2026-08-27, both containers back to back on one machine, chromium
151.0.7922.34 both sides, PW 1.62.1.

**PartitionAlloc-as-malloc is ACTIVE on our musl build — the allocator lead is
dead.** `nm -D` on both `chrome-headless-shell` binaries:
`malloc`/`free`/`calloc`/`realloc`/`memalign`/`posix_memalign`/`malloc_usable_size`
are **all `T` (defined locally) on BOTH sides**; PartitionAlloc strings 28 ours vs
44 official. Nothing in `args.gn.overlay` or aports disables it (the only aports
allocator patch is `partalloc-no-tagging-arm64.patch`). Firefox's gap existed
because official FF statically links mozjemalloc while ours fell through to musl;
**chromium never falls through on either side**, so do not spend a dispatch on a
mimalloc preload here. [[project_ff_build_missing_pgo_lto_jemalloc]]

**`launch` 1.61x is the dynamic closure.** `chrome-headless-shell --version`
(exec + link + minimal init + exit), 30 iterations, 3 interleaved rounds to
control drift:

| round | alpine | official |
|---|---|---|
| 1 | 23.5 ms | 13.9 ms |
| 2 | 26.1 ms | 13.7 ms |
| 3 | 26.1 ms | 14.6 ms |

Median **26.1 vs 13.9 = 1.87x**, ~**+12 ms per exec**, non-overlapping and stable.
Static shape: `DT_NEEDED` **43 vs 28**, `ldd` closure **65 vs 52**, dynamic symbols
**4743 vs 2780**. The 15 extra direct entries are exactly the `USE_SYSTEM_LIBS`
set. `ctypes.CDLL` of those 19 extra DSOs inside our container costs **11.3 ms**,
the same order. chromium pays it twice per `launch()` (browser + `--type=zygote`),
so ~24 ms of the 64 ms gap — **a third to a half, not all of it**; the remainder is
browser-process init (V8 snapshot, mojo, ICU, `.pak`) and belongs to the known
~1.12 geomean residual.

**Excluded on the way** (do not re-propose): lazy-vs-eager binding —
`LD_BIND_NOW=1` on official costs **0.6 ms**, not 12, so musl's always-eager
binding is not it. Fontconfig cold scan — both images ship a prebuilt cache. Reloc
volume — `.rela.dyn` 12.25 MB ours vs 13.06 MB official.

**The fix is a REBUILD and it is expensive.** Drop the pure-compute libraries from
`USE_SYSTEM_LIBS` in
`playwright/alpine-browsers/chromium-headless-shell/scripts/apply-and-build.sh`:
`zlib brotli crc32c double-conversion highway libjpeg libwebp opus dav1d zstd
libxml libxslt`. **Keep `fontconfig` system** — that file's own comment records
that bundled fontconfig uses `initstate_r`/`random_r`, absent in musl; keep
`freetype`/`harfbuzz`/`libdrm` system too. That file is in the setup layer, so it
is a cold r1..r12, **25-30 h** ([[project_chromium_round_images_sha_keyed]]).
Expected: `launch` 1.61 -> ~1.35-1.40, plus a slice of `context_page` and
`goto_cold`, and it carries the zlib/SIMD-deflate screenshot win in the same edit
([[project_png_encoder_exposure_by_browser]]).

**Do `perf record` FIRST.** It costs an hour, needs no rebuild, is the instrument
both the screenshot residual and the 12% geomean residual are waiting on, and
could change what goes into that 25-30 h build. Blocked locally
(`perf_event_paranoid=4`, [[reference_jean_no_passwordless_sudo]]) so it wants a
CI dispatch. [[project_chromium_residual_gap_candidates]]
