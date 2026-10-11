Parked and user-requested memories. Small enough to be complete here — there is
no category index to route to; read `.agents/requested-memory/<slug>.md` for the
memory itself.

- [Parked: chromium promote gate + PGO comment](parked_chromium_promote_and_pgo_comment.md) — chs-latest points at the ThinLTO arm, promote is branch-blind, args.gn PGO comment stale; parked 2026-08-21 behind the bench comparison
- [Alpine apk bug draft](alpine-apk-bug-draft.md)
- [chromium from-source stuck analysis](chromium_from_source_stuck_analysis.md)
- [Perf budget gate — SHIPPED](parked_perf_budget_gate_design.md) — built and merged as PR #195 on 2026-09-09; kept for the design rationale and the budget-sizing correction (seed off single-shot p99, not the median)
- [Open user rulings carried across sessions](open_user_rulings_carried_across_sessions.md) — ALL RULED 2026-10-11 (table applied, fix140 deleted, #259 closed into #249); add new items here as they come
- [Parked: the *-for-testing image family](parked_for_testing_image_family.md) — jean 2026-09-24: BRP-off + the below-official #259 candidates + the Thorium lore flags + -march=v3 all park into a chr-/ffx-/wk-for-testing line whose contract says lower security, testing only; default tags keep official hardening
- [Parked: node driver on mimalloc-insecure — security note](parked_node_driver_mimalloc_insecure_security.md) — 2026-10-06 container-wide LD_PRELOAD secure→insecure for speed (eval_rtt 0.93x); hardening trade-off parked, revisit with #259 / for-testing split
- [Parked: chromium residual tracks 2026-10-08](parked_chromium_residual_tracks_2026_10_08.md) — A2-A9, B3-B5, C2-C7 parked while A1/B1/B2/C1 ran; resume on ask
- [Parked: WebKit PW 1.64 series for the next upgrade](parked_wk_pw_1_64_series.md) — branch parked/wk-pw-1.64-series (1e9d2b1f pin + auth both-shapes shim), reverted d956f38; tag→base→rev map; resume only when PW_VERSION moves
- [Chromium fmod via libm-fmod-custom — MERGED](parked_chromium_fmod_beyond_parity.md) — V8 x64 % → C call, PR #333 squash da27a88 2026-10-11 after 12 AMD + 2 Intel perf-gate draws (libm_fmod 0.31-0.81 vs chs-latest)
