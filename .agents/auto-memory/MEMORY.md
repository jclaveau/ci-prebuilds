Memory index — a router, not a catalogue. Each heading names a category, the
number of memories it really holds, and the index file listing all of them. The
lines under it are only the handful that come up most often.

Most memories are reachable ONLY from a category's index file, so whenever a task
touches an area, read that file before concluding no rule exists. Then read
`.agents/auto-memory/<slug>.md` for the memory itself.

## chromium-perf (16) — the residual-gap campaign: measured, dead, and still open
`.agents/auto-memory/index/chromium-perf.md`

- [chromium residual: musl memset is the hot symbol, unwinder blind, counting preload is the instrument](project_chromium_residual_gap_candidates.md) — dead: allocator, fonts, libc++ hardening, orderfile, CFI, TLS, under-inlining; ROUND 6 profiled it (run 34406201201) and musl `memset` is the hottest symbol vs glibc IFUNC avx2+ERMS; shares are runner-CPU-dependent so only within-run facts hold; ROUND 7: fp/dwarf cannot walk out of memset, PR #211 counts calls by size instead (run 34584573960), PR #215 fixes the blind official leg
- [chromium launch = the DSO closure; PartitionAlloc is fine](project_chromium_launch_dso_closure.md) — 43 DT_NEEDED vs 28, 1.87x per exec paid twice per launch(); allocator lead DEAD on
- [chromium perf arms for 1.62 — PGO+ThinLTO together wins](project_chromium_perf_arms_1_62.md) — geomean vs official: baseline 1.42, PGO 1.28, ThinLTO 1.31, BOTH 1.12
- [The AVX2 string shim was a net loss — RETRACTED](project_chromium_faststring_moves_layout_text.md) — the layout_text win was measured on the artifact at `image_ours`, a DIFFERENT build

## chromium-build (13) — from-source rounds, gn args, caches, base images
`.agents/auto-memory/index/chromium-build.md`

- [chromium round images are sha-keyed](project_chromium_round_images_sha_keyed.md) — any setup-layer edit = full cold r1..r12; cold chromium 151 is 25-30h (r1 boxed at
- [Chromium build time is cold-vs-warm, not PGO/LTO](project_chromium_build_time_is_cold_vs_warm_not_pgo.md) — 22 chains since July: before the knobs 36.1-44.5h, after 36.5-40.3h
- [sccache ghac: broken at 0.15, WORKS at 0.16](project_sccache_ghac_readonly_v18.md) — 0.15+opendal wrote the deprecated v1 path and flipped read-only; 0.16.0 +

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

## conformance (25) — the Playwright suite — skips, runner config, triage recipes
`.agents/auto-memory/index/conformance.md`

- [WK conformance residual, Aug 2026](project_wk_conformance_residual_aug2026.md) — per-cluster verdicts (camera/mic genuine gap, modernizr key is `fontdisplay` not
- [WK camera/mic — PW never wires permissions to getUserMedia](project_wk_camera_mic_and_noxserver_dispositioned.md) — bootstrap.diff wires `permissionForAutomation` into
- [The conformance runner mirrors the consumer by hand](project_conformance_runner_mirrors_consumer.md) — `build-runner.sh` rewrites its own `pw_run.sh`, so a preload added only in
- [PW annotations decide a conformance red](project_pw_test_annotations_shape_conformance.md) — test.fail / host-gated isFrozenWebkit skips; PW 1.62.1 ships wk r2336 off base
- [Headed chromium DCHECK/SYS_NICE fix](project_chromium_headed_dcheck_sys_nice.md) — chr-fs browser-deaths = DCHECK_ALWAYS_ON + setpriority-EPERM; fix `--cap-add

## measurement (17) — probes, ratios, controls, and what a number does NOT mean
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

## images (17) — docker layering, dind/dood, UID handling, strip passes
`.agents/auto-memory/index/images.md`

- [Strip before the final COPY, not after](project_strip_must_precede_final_copy.md) — layer blobs are immutable, so post-COPY `rm` never shrinks the published image
- [All-3-browsers alpine image](project_all_browsers_alpine_image.md) — chs+ff+wk headless in Dockerfile.alpine; WebKit needs seccomp=unconfined +
- [dind sudoers named paths that don't exist](project_dind_sudoers_paths_unmatched.md) — /usr/sbin/dockerd, /usr/bin/chown on Alpine; rules never matched, only the hardened
- [Docker engine moved out of dood into dind](project_docker_engine_out_of_dood.md) — dood can't use a local daemon; 794 → 719 MiB, engine is 157 MiB of the shared base

## playwright-pins (13) — PW versions, browser revs, aports pins, renovate
`.agents/auto-memory/index/playwright-pins.md`

- [PW release tags can pin two different firefox versions](project_pw_release_tag_pins_disagree.md) — v1.60.0 browsers.json 150.0.2 vs UPSTREAM_CONFIG 147.0.1; we built and shipped
- [WebKit version assertions](project_webkit_version_assertions.md) — `browser.version()` is a hardcoded playwright-core constant (vacuous); real signals
- [The aports pkgver rule had drifted in two of three copies](project_aports_pkgver_rule_drift.md) — mirrors claiming to mirror apply-and-build.sh kept strict equality after it went

## process (8) — how to work in this repo
`.agents/auto-memory/index/process.md`

- [Merge my own green PRs here — jean does not review](feedback_merge_without_review_here.md) — he builds the CI that produces the numbers; closing the loop (merge → dispatch →
- [Check a source-only patch reaches the build](project_source_patch_reaches_build_checklist.md) — before a multi-hour dispatch: image tag sha-scoped? script COPYed before the RUN
