---
name: open_user_rulings_carried_across_sessions
description: small housekeeping/scope decisions that are jean's call, unresolved across many /compact cycles as of 2026-09-24 — surface them next time he's free, don't decide unilaterally
metadata:
  type: project
---

These have been carried verbatim in this session's /compact summaries since at
least 2026-09-16 without ever reaching a decision. None are blocking; they're
listed here so a future session (or a fresh one after a `/clear`) doesn't lose
them entirely once the compaction chain that was carrying them ends.

- **`tmp/scratch-mem/`** (created 2026-09-16) — no longer present as of
  2026-09-24; deleted at some point without an explicit ruling landing here.
  Superseded by **`tmp/perf-run`** (present since 2026-09-23, unchanged as of
  2026-09-24) — same open question, keep or delete, still unruled.
- **`.mem-auto-*` scratch** (`tmp/.mem-auto-{delta,files,summary,await-ctx,last}*`)
  — transcripts, file-list snapshots, handoff summaries and locks from the
  `/mem` auto-handoff hook; 17+ handoff summaries accumulated by 2026-09-24
  with none ever cleaned. Cleanup pass is jean's call, proposed twice, no
  ruling yet.
- **Two branches pushed, no PR opened** (per "ask before opening a PR"),
  both as of 2026-09-24:
  - `perf/wk-pgo-corpus` (`d269561`) — candidate B, cancelled by jean
    ("no shared pgo corpus for wk, work on other projects for now"); also
    needs a rebase onto `perf/wk-pgo`'s fixed tip
    ([[project_wk_pgo_continuous_mode_value_profiling]]) before it could
    ever run again.
  - `tools/gha-contention` (`7a948eb`) — a GHA contention-check script
    (`scripts/gha-contention.sh`), used successfully from the branch
    (`gh api` runs/jobs, reports running/queued per workflow) to confirm a
    WK PGO redispatch wasn't parked behind four chromium candidates. Works;
    just never merged.
- **`fix140` branch** (7 superseded commits, no PR) + its 3 superseded
  stashes — jean's own earlier call was to keep them; still sitting there.
- **`from_stage=playwright` TP dispatch lever** — a proposed workflow input,
  never actioned.
- **Issue #259's hardening-removal ladder** — 7 ranked candidates
  ([[project_chromium_hardening_removal_candidates]]), gated behind #249,
  queued but none dispatched.
- **`perf/chromium-cfi-snapshot-clang` branch** — RESOLVED 2026-09-21:
  jean ruled "ship snap" after 5 A/B draws read snap/cfi geo 0.96–0.99
  (the 09-19 DEAD call was n=1); PR #273 merges it, branch goes with the
  merge ([[project_chromium_residual_gap_candidates]]).
- **`assert-perf-gate.py:57` margin_for() dead-code bug** (found 2026-09-24)
  — RULED, firefox half SHIPPED: jean questioned the proposed fix ("loosens
  the gate... that's odd"); CV analysis showed the bug's accidental effect
  (tight margin wins) was CORRECT, the `loose` list's intent was wrong.
  Fix was deleting firefox's `js_alloc`/`launch` from `loose`, not swapping
  precedence — opened as PR #312 (`perf/ff-gate-margins`, fa16569), CI
  draining at last check. Webkit half still blocked on a non-skipped
  `perf-gate-webkit` run supplying CV data for webkit's own loose rows.
  See [[project_perfgate_vs_tpprobe_rules_differ]].
- **PR #311 (`perf/wk-mimalloc-no-purge`) — close or keep?** (2026-09-24)
  — the mimalloc no-purge env change is green but measured a wash:
  `perf-probe.yml` n=10 on 7763+9V74 read geomean 1.00 both CPUs, no row
  moved >2%. Confirmed 36% page-fault cut, zero wall payoff. Left unmerged
  on purpose (measuring before merging was the point of the PR); jean has
  not yet said whether to close it or merge anyway for the fault-cut alone.
  See [[project_wk_mimalloc_purge_delay_finding]].
- **fastfmod rename — DONE 2026-10-09** (3323d08 on `perf/fmod-fprem126`,
  branch only). Now `playwright/alpine-browsers/libm-fmod-custom/`,
  `libm-fmod-custom-gate.yml` covers WebKit's .so AND Firefox's gcc-.s-by-clang23
  form. WebKit preload on the branch builds from the unified source; shipping
  it = merge, jean's call. Firefox build 37925571320.
  See [[project_fmod_everywhere_preload_vs_patched_musl]].

**How to apply:** don't act on any of these without asking — they're
explicitly jean's call, not a default. Worth a one-line mention next time
there's idle capacity (e.g. between long CI chains) rather than raising them
mid-task.
