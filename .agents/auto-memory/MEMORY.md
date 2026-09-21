Memory index — a router, not a catalogue. Each heading names a category, the
number of memories it really holds, and the index file listing all of them. The
lines under it are only the handful that come up most often.

Most memories are reachable ONLY from a category's index file, so whenever a task
touches an area, read that file before concluding no rule exists. Then read
`.agents/auto-memory/<slug>.md` for the memory itself.

## chromium-perf (26) — the residual-gap campaign: measured, dead, and still open
`.agents/auto-memory/index/chromium-perf.md`

- [chromium layout gap is FRONTEND FETCH, code layout](project_chromium_layout_gap_is_frontend_fetch.md) — reflow: iTLB 2.3x, icache 1.4x, fetch-latency 2x per instruction, hot code over 1.6x more text pages; boxonly flat; tracing says every Blink phase pays the same factor (uniform), only Skia Raster stands out
- [PGO only applies with CFI ON](project_chromium_pgo_hash_needs_cfi.md) — is_cfi=false breaks the profile hash on exactly the hot functions (100% of layout counts dropped); SHIPPED (PR #260, geo 0.94, layout 0.74, launch 1.10 — real CFI tax, official pays it too)
- [clang 22→23 IS a layout lever](project_chromium_clang23_lever.md) — layout 0.87x vs shipped on slow silicon, vs official 1.40 (was 1.61), geomean 1.10; SHIPPED 2026-09-15 (#243, promote 34902520647); residual vs official layout 1.19× on 9V74
- [chromium nav gap is musl fortify's inline memcpy OVERLAP check](project_chromium_nav_gap_is_musl_fortify_overlap_check.md) — CLOSED by the snapshot toolchain (Viz/raster at parity 2026-09-21); was: goto_warm +50% instructions at higher IPC = Skia lowp raster on VizCompositorTh/raster workers (renderer main at parity); every fixed-size memcpy carries fortify-headers' two-range compare + ud2 that glibc's __memcpy_chk never emits; the driver audit missed it (grepped __*_chk); lever measured via the fortify-free snapshot-clang build: −3% nav wall (raster is off the critical path), SHIPPED PR #273; header variants subsumed
- [CAMPAIGN REOPENED — startup closed by tz fix, nav/layout/input/screenshot are real](project_chromium_residual_gap_candidates.md) — layout at PARITY on 8573C, nav residual = renderer main thread + system libharfbuzz (PR #277 text stack in-tree); 18-draw/4-cpu sample: startup 1.05x IS noise (PR #266 holds); nav 1.06-1.14x, layout 1.11x (EPYC), input 1.02-1.06x, screenshot 1.24-1.50x (Intel) are real; bar now ≤1.00; PR #268 counters show nav is +50% instructions but BETTER fetch, opposite of the old layout shape
- [chromium launch gap RESOLVED — DSO closure, consumer image, then ICU](project_chromium_launch_dso_closure.md) — trim shipped (0.79x); base arm localized cost to consumer image (1.27x vs scratch parity); root cause = ICU walking 600 tzdata files vs missing /etc/localtime (strace: +9,300 file syscalls/launch); fixed by symlink PR #266; post-fix: startup 1.16x→~1.05x, campaign closed
- [chromium perf arms for 1.62 — PGO+ThinLTO together wins](project_chromium_perf_arms_1_62.md) — geomean vs official: baseline 1.42, PGO 1.28, ThinLTO 1.31, BOTH 1.12
- [The AVX2 string shim was a net loss — RETRACTED](project_chromium_faststring_moves_layout_text.md) — the layout_text win was measured on the artifact at `image_ours`, a DIFFERENT build
- [Beyond parity: an issue for hardening a test container doesn't need](project_chromium_hardening_removal_candidates.md) — issue #259, 7 ranked candidates (cfi-icall off first), gated behind #249
- [Thorium audit — not a drop-in, 2 codegen levers worth porting](project_chromium_thorium_audit.md) — 138 LTS vs PW's 151, no headless_shell target; libc++ hardening FAST + AVX2/FMA baseline are the reusable levers, BOLT/Polly dead on Alpine

## chromium-build (15) — from-source rounds, gn args, caches, base images
`.agents/auto-memory/index/chromium-build.md`

- [chromium round images are sha-keyed](project_chromium_round_images_sha_keyed.md) — any setup-layer edit = full cold r1..r12; cold chromium 151 is 25-30h (r1 boxed at
- [Chromium build time is cold-vs-warm, not PGO/LTO](project_chromium_build_time_is_cold_vs_warm_not_pgo.md) — 22 chains since July: before the knobs 36.1-44.5h, after 36.5-40.3h
- [sccache ghac: broken at 0.15, WORKS at 0.16](project_sccache_ghac_readonly_v18.md) — 0.15+opendal wrote the deprecated v1 path and flipped read-only; 0.16.0 +
- [A self-built lld's stack-size default crashed a big CFI+ThinLTO link under musl](project_chromium_snapshot_lld_stack_overflow.md) — PT_GNU_STACK memsz 0 vs Alpine lld23's 2 MiB; musl gives threads 128 KiB; `mksnapshot` overflows; fix `-Wl,-z,stack-size=2097152`

## webkit-perf (17) — the WebKit gap campaign — allocator, loader, fmod, Skia
`.agents/auto-memory/index/webkit-perf.md`

- [musl's fmod is all of libm_fmod, and the rewrite ships gated](project_wk_fastfmod_ships.md) — glibc 54 ms / musl 164 ms per 3M; a branchless drop-in preloaded beside mimalloc
- [WebKit's launch gap: every loader candidate is dead](project_wk_launch_is_the_loader.md) — ours has FEWER relocations (320,694 vs 339,342) and a SMALLER .text; DSO closure
- [WebKit's screenshot gap was Alpine's -Os libpng](project_wk_screenshot_is_alpine_os_libpng.md) — perf record put 81% of a shot in libz+libpng; NOT SIMD, NOT hardening, and Ubuntu
- [WebKit's launch row is Mesa in the closure](project_wk_launch_is_mesa_in_the_closure.md) — Alpine has no libglvnd, so `mesa-egl` IS libEGL.so.1 and DT_NEEDs libgallium (44

## webkit (17) — WPE/GTK build, PW patch series, browser-side bugs
`.agents/auto-memory/index/webkit.md`

- [PW's WebKit base lags the browser it ships](project_pw_webkit_base_lags_shipped_build.md) — v1.62.0's UPSTREAM_CONFIG names an April WebKit but the shipped webkit-2336 is past
- [WebKit CacheStorage records are unreadable — RESOLVED](project_wk_cachestorage_disk_records_invisible.md) — PW's bootstrap.diff patches decodeForPersistence to read httpRequestHeaderFields
- [WebKit page.close() hangs — missing Playwright.closePage](project_wk_closepage_hang.md) — PW's published bootstrap.diff omits the command (all tags + main); sendMayFail
- [WebKit strip + GTK gate + promote](project_webkit_strip_gtk_gate_promote.md) — 2026-08-01: finalize strips ELF symbols (WPE-only), GTK gated off by default

## firefox (8) — mozconfig, build passes, FF-side bugs
`.agents/auto-memory/index/firefox.md`

- [FF's gap vs official was the ALLOCATOR — RESOLVED](project_ff_build_missing_pgo_lto_jemalloc.md) — official links mozjemalloc (`malloc` undefined 0 vs our 1); mimalloc preload in the
- [Firefox PNG: bytes fixed, TIME did not follow](project_ff_png_encoder_gap.md) — libpng+zlib must ship as a pair (system libpng brings its own libz) and reaches

## conformance (26) — the Playwright suite — skips, runner config, triage recipes
`.agents/auto-memory/index/conformance.md`

- [WK conformance residual, Aug 2026](project_wk_conformance_residual_aug2026.md) — per-cluster verdicts (camera/mic genuine gap, modernizr key is `fontdisplay` not
- [WK camera/mic — PW never wires permissions to getUserMedia](project_wk_camera_mic_and_noxserver_dispositioned.md) — bootstrap.diff wires `permissionForAutomation` into
- [The conformance runner mirrors the consumer by hand](project_conformance_runner_mirrors_consumer.md) — `build-runner.sh` rewrites its own `pw_run.sh`, so a preload added only in
- [PW annotations decide a conformance red](project_pw_test_annotations_shape_conformance.md) — test.fail / host-gated isFrozenWebkit skips; PW 1.62.1 ships wk r2336 off base
- [Headed chromium DCHECK/SYS_NICE fix](project_chromium_headed_dcheck_sys_nice.md) — chr-fs browser-deaths = DCHECK_ALWAYS_ON + setpriority-EPERM; fix `--cap-add

## measurement (18) — probes, ratios, controls, and what a number does NOT mean
`.agents/auto-memory/index/measurement.md`

- [musl is not why alpine browsers are slower](project_alpine_browser_perf_vs_glibc.md) — FF and WK at parity or FASTER than official glibc; only chromium regressed (build
- [The perf-probe ratio is runner-CPU-dependent](project_perf_probe_ratio_is_cpu_dependent.md) — each run is internally runner-divided but two runs still cannot be differenced
- [PNG encoder exposure by browser](project_png_encoder_exposure_by_browser.md) — only FF paid it; wk and chr match official byte-for-byte on the canvas control
- [Probe font mismatch confounds layout](project_probe_font_mismatch_confounds_layout.md) — the fixture sets no font-family; ours resolves FreeSans, official's collapses

## ci-workflows (21) — GHA mechanics, dispatch, promote gates, reading a run
`.agents/auto-memory/index/ci-workflows.md`

- [WebKit promote gate — RESOLVED](project_wk_promote_gate_holds_the_nightly_bench.md) — the three conformance-webkit blockers (camera/mic #112, CacheStorage #116
- [Promote gates differ per browser](project_promote_gates_by_browser.md) — chromium-from-source promotes chs-latest from ANY branch on a green dispatch; read
- [TP paths-ignore can silently un-ship a fix](project_tp_paths_ignore_ships_nothing.md) — fastfmod/** and strip-bundled-libs.sh live under the ignored
- [GHA concurrency group serializes dispatches](project_gha_concurrency_group_serializes_dispatches.md) — `group: <name>-${ref}` + `cancel-in-progress: false` blocks parallel dispatches on
- [A force-push can leave a PR with ZERO runs](feedback_force_push_may_not_retrigger_ci.md) — after a rebase `gh pr checks` said "no checks reported" while the OLD sha's green

## images (18) — docker layering, dind/dood, UID handling, strip passes
`.agents/auto-memory/index/images.md`

- [Consumer pull is bytes-bound, not layer-bound](project_image_pull_is_bandwidth_bound.md) — concurrency 3→8 is noise; the chromium wrapper rename had duplicated the binary layer (#255, −10% bytes, −7% pull); bench with `image-pull-bench.yml`
- [Strip before the final COPY, not after](project_strip_must_precede_final_copy.md) — layer blobs are immutable, so post-COPY `rm` never shrinks the published image
- [All-3-browsers alpine image](project_all_browsers_alpine_image.md) — chs+ff+wk headless in Dockerfile.alpine; WebKit needs seccomp=unconfined +
- [dind sudoers named paths that don't exist](project_dind_sudoers_paths_unmatched.md) — /usr/sbin/dockerd, /usr/bin/chown on Alpine; rules never matched, only the hardened
- [Docker engine moved out of dood into dind](project_docker_engine_out_of_dood.md) — dood can't use a local daemon; 794 → 719 MiB, engine is 157 MiB of the shared base

## playwright-pins (13) — PW versions, browser revs, aports pins, renovate
`.agents/auto-memory/index/playwright-pins.md`

- [PW release tags can pin two different firefox versions](project_pw_release_tag_pins_disagree.md) — v1.60.0 browsers.json 150.0.2 vs UPSTREAM_CONFIG 147.0.1; we built and shipped
- [WebKit version assertions](project_webkit_version_assertions.md) — `browser.version()` is a hardcoded playwright-core constant (vacuous); real signals
- [The aports pkgver rule had drifted in two of three copies](project_aports_pkgver_rule_drift.md) — mirrors claiming to mirror apply-and-build.sh kept strict equality after it went

## process (9) — how to work in this repo
`.agents/auto-memory/index/process.md`

- ["tally" = `pnpm tally`](feedback_tally_is_the_script.md) — run scripts/tally.py and relay it; builds + ETA, conformance verdicts, perf ours/official per group and geomean, per CPU and global; never hand-assemble
- [Merge my own green PRs here — jean does not review](feedback_merge_without_review_here.md) — he builds the CI that produces the numbers; closing the loop (merge → dispatch →
- [Check a source-only patch reaches the build](project_source_patch_reaches_build_checklist.md) — before a multi-hour dispatch: image tag sha-scoped? script COPYed before the RUN
- [PGO probe mechanics](project_chromium_pgo_probe_mechanics.md) — gn `obj/<dir>/<target>/x.o` naming, IR profiles need `--counts` + max Block counts, busybox has no `join`, empty log ≠ zero mismatches, `script_ref` dispatch
- [chromium libc ladder: flags arm + Debian-sysroot arm](project_chromium_libc_ladder.md) — aports' compiler.patch strips 3 official codegen flags (regalloc split-threshold, lifetime-dse, ubsan-feature); glibc chromium on an Alpine host needs a real bullseye runtime for the host tools (every sysroot .so is a stub; a NEEDED missing from it loads musl and segfaults) + a glibc-hosted rustc; libc arm DEAD in r5, parked
