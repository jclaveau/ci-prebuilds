---
name: project_perf_branch_fixes_rot_on_main
description: build fixes worked out on a long-lived perf branch never reach main, and dispatch-gating hides it — main's chromium from-source path was unbuildable for ~3 months
metadata:
  type: project
---

The chromium-151 gn peel (`enable_print_preview`/`enable_basic_printing` back
ON with `use_cups` still off, plus `pipewire-dev` and `go` in the setup image)
was worked out on `perf/chromium-pgo-thinlto-1.62` and **never came back to
main**. main kept `enable_print_preview = false` untouched since c093eca
(2026-06-02), so the first dispatch off main died four minutes in on
`assert(enable_print_preview)` — before compiling anything. Ported in 3ff90b8.

**Why nothing noticed:** every browser build here is dispatch- or label-gated,
and push-to-main only builds firefox. A broken chromium/webkit recipe on main
therefore produces no signal at all until someone dispatches from main — and
for months nobody did, because the perf branch had the working config and was
where the interesting builds ran. Green main means nothing about these paths.

**How to apply:** when a build fix is found while iterating on a perf/experiment
branch, port it to main in its own commit the same day, comments included — the
comments name the runs that established each flag and are what stops it being
re-litigated. Before trusting any "main is fine", check whether main has ever
actually run the job in question ([[project_promote_gates_by_browser]] for the
same shape in the promote direction). Diffing the settings of a branch artifact
that DID build against main is the cheap check when the failure costs a 15 GB
fetch to reproduce ([[feedback_verify_ab_varied_the_variable]]).

Adjacent: [[project_finalize_overlay_baked_scripts]] (an edit that never reaches
the image), [[project_ff_prebuilt_base_pin_only_tag_staleness]] (a stale base
reused because the tag did not move).
