---
name: project_chromium_launch_dso_closure
description: the DSO closure is the launch gap and the USE_SYSTEM_LIBS trim IS worth it — a per-object census says all sixteen shared objects unload, 65 -> 49 DSOs (official has 51) and loader work bound 0.65x; --no-zygote is NOT a lever (saves 19% on BOTH libcs); PartitionAlloc is ACTIVE on musl so there is no allocator win
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

**RE-MEASURED on a quiet runner, 2026-09-09 — the closure is a quarter of the
gap, not a third to a half.** The numbers above (26.1 vs 13.9 ms, "+12 ms per
exec") were taken where the control read 13.9 ms; on a hosted runner the same
kernel reads:

| | ours (musl) | official (glibc) | ×off |
|---|---|---|---|
| fork+exec control (`/bin/true`) | 0.7 ms | 0.7 ms | 1.00x |
| `--version` wall | 13.8 ms | 8.3 ms | 1.67x |
| **load** (wall minus control) | **13.1 ms** | **7.6 ms** | **1.73x** |

The RATIO held (1.73 against 1.87) and so did the shape — `closure-dsos` 65 vs
51, `closure-symbol-relocs` **13,373 vs 6,739 (1.98x)**, while
`closure-relative-relocs` are FEWER on our side (509,760 vs 558,875, 0.91x), so
what we pay extra for is symbol binding, not relocation volume. What did not
hold is the absolute: **+5.5 ms per exec**, twice per `launch()` = ~11 ms of
the 48 ms gap (154.7 vs 106.4 on a 7763). About 23%.

**CENSUSED 2026-09-09, run 34339130160 — every one of the sixteen shared
objects unloads, and the closure lands on official's number.**
`dso-symbol-census.cjs` walks the closure, attributes relocations per object
and asks of each trimmed library whether anything we KEEP still needs it. The
prediction going in was that most would stay — libz for the
fontconfig/freetype/harfbuzz stack, libxml2 for something in the X or dbus
chain — and that the trim would therefore free references without shortening
the object list. That was wrong: nothing outside chromium itself needs any of
them, and the closure would go

| | today | after the trim |
|---|---|---|
| DSOs the loader walks | 65 | **49** (official is 51) |
| symbol relocations | 16,914 | 14,469 (-14.5%) |
| undefined references | 6,792 | 5,880 (-13.4%) |

musl resolves every reference against the loaded-object list, so the loader's
work is bounded by references x objects: **0.65x of today's**. That is an upper
bound rather than a prediction, but it is a far better-founded reason to run
the rebuild than the one this file previously recorded, and the trim is
already dispatched as `perf/chromium-unbundle-libs`.

(The census totals 16,914 symbol relocations where `closure-reloc-audit.sh`
reports 13,373 for the same closure: the census counts `R_X86_64_64` beside
`JUMP_SLOT` and `GLOB_DAT`. Compare each instrument to itself.)

**The SHIPPED image is not the explanation either (run 34342006293).** The
consumer image was the obvious suspect for the campaign reading `launch` 1.40
and `layout` 1.62 where the from-source artifact reads 1.19 and 1.29 on the
same 7763 — WebKit had exactly that bug, where Alpine's libEGL pulled
libgallium and libLLVM into every launched process. It does not replicate:

| | shipped image | scratch artifact |
|---|---|---|
| closure DSOs | 66 | 65 |
| symbol relocations | 13,493 | 13,387 |
| `layout_boxonly` ×off | 1.32x | 1.27x |
| `layout_text` ×off | 1.26x | 1.28x |

Two notes from running it. The shipped `chrome-headless-shell` IS the launch
shim — a /bin/sh script that sets LD_PRELOAD and execs `.real` beside it — so
every ELF instrument must read `chrome-headless-shell.real` or it fails with
"Not an ELF file". And the consumer image installs playwright with pnpm, so
`npm root -g` does not find it; use `playwright/scripts/global-node-path.sh`.

**What is left is that the two layout numbers are different kernels.**
`runtime-probe.cjs`'s `layout` is 16,000 forced synchronous reflows of ONE
element; `chromium-gap-probe.cjs`'s `layout_boxonly` changes a container and
re-lays-out 800 children. The first is far more call-dense, which is the shape
the stack protector taxes hardest — so it is plausibly the row the SSP-parity
build moves, and not an instrument error at all.
[[project_runtime_probe_rows_are_batches]]

**`--no-zygote` is NOT a lever — it is process startup.** `launch()` execs a
browser, a zygote and a renderer; dropping one exec saves **19.0% on ours and
18.3% on official** (119.7 -> 96.9 against 101.0 -> 82.5, 40 s steady-state
loops, one 7763). The ratio moves 1.19x -> 1.18x. A saving that lands equally
on glibc is not the musl loader, and the flag buys nothing for parity.

The other ~37 ms is browser-process init and has never been profiled. The
`launch` kernel added to `perf-kernel.cjs` is the instrument; it is standalone
(it owns its browser per iteration) because the lifecycle IS the measurement.

Measured by `playwright/bench/startup-time.cjs` + `closure-reloc-audit.sh` in
the `chromium-gap-probes` static arm, run 34303549522.

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
