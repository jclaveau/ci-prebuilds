---
name: project_chromium_launch_dso_closure
description: the DSO closure is the launch gap and the USE_SYSTEM_LIBS trim IS worth it — MEASURED 2026-09-11 launch 0.79x on the unbundle arm (2f82e9e), text stack adds nothing (0.81x), layout unreadable at this n; census said 65 -> 49 DSOs (official 51), loader work bound 0.65x; --no-zygote is NOT a lever (saves 19% on BOTH libcs); PartitionAlloc is ACTIVE on musl so there is no allocator win; REVERSED 2026-09-18 — base arm (n=5) shows the shipped consumer image alone pays launch 1.27x on 7763 / 1.17x Xeon while the scratch artifact hits glibc parity on any alpine base; the Vulkan ICD candidate priced at ~4 ms of ~27 (35303365205); the rest is ICU's uprv_tzname() walking 600 tzdata files against a missing /etc/localtime — 9,300 extra file syscalls per launch, found by strace, fixed by one symlink (PR #266); RESOLVED 2026-09-18 — post-fix TP read: startup 1.16x -> ~1.05x, geomean 1.05, campaign closed, no residual row left
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

**The trim's BUILD cost, priced 2026-09-09 from ninja's own counter.** Round 2
of each chain reports its target total: main (SSP-parity) 22,275, the
`perf/chromium-unbundle-libs` chain **23,677**. So dropping the libraries from
`USE_SYSTEM_LIBS` adds **1,402 targets, +6.3%** — chromium compiling its own
zlib/brotli/libxml2/etc. instead of linking Alpine's. That is far cheaper than
feared and does not threaten the round budget.

Read a chain's ETA the same way rather than guessing: `gh api
.../actions/jobs/<id>/logs | grep -oE "\[[0-9]+/[0-9]+\]" | tail -1`. Rounds are
boxed near 5h10m, r1 did 7,899 targets and r2 4,887 (later TUs are bigger), so
~946/h against 17,388 remaining puts a cold chain at **five or six rounds, not
the configured twelve** — the max exists for headroom, and quoting 12 x 5h as
the ETA overstates it by two days.

**MEASURED 2026-09-11 — the trim delivers the launch, the text stack adds
nothing.** Three `chs-perf-ab` runs, candidate/baseline, 4 launch samples each:

| pair | run | CPU | launch | samples (ms) |
|---|---|---|---|---|
| shipped `d4e5f6b` → unbundle `2f82e9e` | 34619831658 | Xeon | **0.79x** | 112-125 → 83-93 |
| shipped → textstack `f967bc4` | 34618356217 | 9V74 | **0.81x** | 103-116 → 83-92 |
| unbundle → textstack | 34619834664 | Xeon | 3.27x n.s. | 93-228 → 218-747: VOID, runner-side |

The two clean runs agree to within 0.02, so the whole gain is the 11-library
re-bundling (`perf/chromium-unbundle-libs`) and freetype+harfbuzz
(`perf/chromium-textstack-bundled`) add no launch on top. `layout` is NOT
readable from these: 0.93x / 0.99x / 0.94x across the three pairs is
inconsistent (0.93 x 0.94 should give 0.87, not 0.99), i.e. inside
run-to-run noise — bracket it before claiming a layout move
([[project_chromium_faststring_moves_layout_text]]). Both chains passed
conformance 20/20; their only red job is `conformance-runtime-parity` at a
head predating PR #207's gate fix. The third run also shows what a VOID
launch cell looks like: every sample 2-5x the other runs' on the same CPU
model while `int_math`/`libm_fmod` sit at 1.02 — process startup drifts
independently of the compute controls, so the invalid-cell gate in
`assert-perf-budgets.py` cannot catch it; a full rerun is the only remedy
(PR #217's first `Test and Publish` read `launch` 2.71x the same way).

**How to apply:** the shipping candidate is unbundle (`2f82e9e`, stale vs
main — rebase, then ~38h build + promote); textstack is not worth carrying.
Expected consumer-image `launch` ≈ 1.33 x 0.79 ≈ **1.05x** vs official.

**The consumer image's `sh` wrapper is NOT a launch lever — PARKED 2026-09-18
(#249 comment).** `Dockerfile.alpine` fronts `chrome-headless-shell` with a
4-line `/bin/sh` script (`unset LD_PRELOAD`, exec `.real`) so the
container-wide driver preload never reaches PartitionAlloc; Playwright itself
needs no wrapper. Measured in `alpine-dood-playwright:sha-370411d4` locally,
interleaved: `launch()` wrapper vs `.real` direct read 0.94 then 1.05 (noise);
exec isolated, `/bin/true` 3.2 ms vs 7.3-9.3 ms through the wrapper, so it is
**+4-5 ms once per launch** (zygote/renderer re-exec `/proc/self/exe` =
`.real`), ~2% of a 240 ms local launch, ~1-2% on a runner — under the row's
run-to-run floor (0.86~ vs 1.18 for one image on 9V74). The 1.43-vs-1.36 in the
Dockerfile comment is libfaststring's DSO, not this wrapper. Removing it means
either dropping the driver mimalloc (eval_rtt -8-13%, net loss) or a static
musl launcher (~1%). Revisit only if startup is the last row standing.

**REVERSED 2026-09-18 — the shipped image IS the explanation after all,
localized by the gap-probes base arm.** The 2026-09-09 verdict above ("the
SHIPPED image is not the explanation either") compared shipped vs scratch
artifact at n=1 and found them close (66 vs 65 DSOs). A proper n=5
interleaved base-arm run (35299149344, EPYC 7763, same binary in all three
images) reverses it:

| kernel | shipped image | scratch (alpine:edge) | scratch (alpine:3.24) | official |
|---|---|---|---|---|
| `launch` (40s kernel) | 132.3 **1.27×** | 105.5 **1.01×** | 106.3 **1.02×** | 104.4 |
| `layout_boxonly`/`layout_text` ×off | 1.08 (both) | 1.08 | 1.08 | — |

Layout stays flat across all three of our images (alpine base version is not
a variable — see [[project_chromium_layout_gap_is_in_our_binary]]), so it is
genuinely binary/codegen. Launch does not: the scratch artifact hits glibc
parity on **both** alpine bases, only the *consumer* image pays +25-27%. On
the prior day's Xeon 8573C read the same comparison was +17% (shipped 114.9
ms vs scratch 98.3 ms vs official 93.9 ms) — same direction, different CPU.
Binary load is equal, so the cost sits above the ELF: driver/env/shim layer,
not codegen.

**Candidate found by direct read: `mesa-vulkan-swrast`, installed only for
WebKit's Mesa dedup, taxes every chromium launch.** It is a top-level apk
install nothing else depends on. It leaves a system Vulkan ICD manifest on
disk; chromium's bundled Vulkan loader (used by the GPU process even
headless) enumerates *all* ICD manifests it finds, so every launch maps
lavapipe + libLLVM (100+ MB of relocations) despite chromium defaulting to
its own bundled SwiftShader. The scratch artifact has no `mesa-vulkan-swrast`
package, no manifest, no enumeration cost — consistent with the base-arm
numbers above. Local A/B (dev box, noisy: load 7-8, swap full, scratch swings
170-192 ms, consumer 199-236 ms) confirmed via `apk info` / loader maps that
both `VK_DRIVER_FILES` pinning and dropping the driver's mimalloc preload
remove lavapipe+LLVM from the process maps, but was too noisy locally to size
the win — **sizing moved to CI, not local**, since local timing under
load 7-8 / full swap is not trustworthy for anything sub-30%.

**PRICED 2026-09-18 (35303365205, 7763, n≈300/leg) — the ICD is the small
one.** `consumer-baseline` 131.4 / `consumer-vkonly` 127.6 / `consumer-nopreload`
135.5 / scratch 104.8 / official 103.5 ms. Pinning `VK_DRIVER_FILES` buys ~4 ms
of a ~27 ms gap; the driver preload buys nothing (the legs are sequential, so
±4 ms is drift). Fontconfig was checked too: caches valid in both images,
consumer just has +20 opensans fonts — dead.

**FOUND by direct read — `strace -f` of one `chromium.launch()` in each
image.** Syscall COUNTS do not care about box load, so this works on a
thrashing dev box where timing does not. The consumer launch makes 11,286 file
syscalls to scratch's 1,934: 6,225 opens under `/usr/share/zoneinfo` + 3,020
on `/etc/localtime`, 1,245 per process in FIVE processes (node, the sh shim,
browser, zygote, network utility). `gtk4.0` (WebKit) pulls `tzdata` in (600
files) but nothing creates `/etc/localtime`. ICU's `uprv_tzname()` reads `$TZ`,
readlinks `/etc/localtime`, and with both missing walks the whole zoneinfo tree
comparing each file's bytes against `/etc/localtime` — every compare fails on
the absent file, so the walk always runs to the end. Scratch has no tzdata and
never walks; the official image symlinks `/etc/localtime` → `Etc/UTC` and
readlink answers in one syscall.

**Fix = one symlink, PR #266**: `ln -sf /usr/share/zoneinfo/UTC /etc/localtime`
in `runtime-libs` (`playwright/Dockerfile.alpine`). Re-traced with the symlink:
2,072 file syscalls (scratch 1,934), zoneinfo opens 6,225 → 15. Respects a
user-set `$TZ`, fixes node and WebKit/Firefox launches too, not only chromium.
The `VK_DRIVER_FILES` export in the shim is a separate ~4 ms follow-up, not
folded in. Read the perf-probe startup row after the TP rebuild before calling
the row closed. Lesson: when timing is unreadable, count syscalls — a
structural diff is load-independent ([[feedback_read_the_stored_value]]).

**RESOLVED 2026-09-18 — TP 35324815014 (consumer rebuild with the tz
symlink) read post-fix.** `perf-probe` on `main` @ 6be10b3: chromium
`startup` 1.16x → **~1.05x** (inside run-to-run noise), geomean 1.07 → 1.05.
Every row now sits ≤1.05 vs official — no row stands out as a residual
anymore. This closes the multi-session "every runtime-probe row ≤ 1.00-1.05x,
conformance green" campaign for chromium the same way it already closed for
Firefox and WebKit ([[project_alpine_browser_perf_vs_glibc]]): the launch gap
was never codegen, it was one missing `/etc/localtime` symlink.
**Confirmed 2026-09-19** by an 18-draw/4-cpu noise check: `startup` spread
0.96-1.06 across every fleet CPU is noise, this row stays closed — the
campaign's OTHER rows (nav/layout/input/screenshot) turned out not to be,
see the reopened [[project_chromium_residual_gap_candidates]]. The parallel
CFI+snapshot-clang chain (`perf/chromium-cfi-snapshot-clang`,
[[project_chromium_snapshot_lld_stack_overflow]]) is still running unwatched
on its own cron-driven schedule as a further optimization, not a fix for an
open gap — nothing is blocking on it. The `VK_DRIVER_FILES` shim export
(~4 ms) remains an optional, un-shipped follow-up.
