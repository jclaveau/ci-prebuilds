---
name: open_user_rulings_carried_across_sessions
description: five small housekeeping/scope decisions that are jean's call, unresolved across 5+ /compact cycles as of 2026-09-19 — surface them next time he's free, don't decide unilaterally
metadata:
  type: project
---

These have been carried verbatim in this session's /compact summaries since at
least 2026-09-16 without ever reaching a decision. None are blocking; they're
listed here so a future session (or a fresh one after a `/clear`) doesn't lose
them entirely once the compaction chain that was carrying them ends.

- **`tmp/scratch-mem/`** (created 2026-09-16) — proposed for deletion, still
  untouched, nobody's ruled on it.
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

**How to apply:** don't act on any of these without asking — they're
explicitly jean's call, not a default. Worth a one-line mention next time
there's idle capacity (e.g. between long CI chains) rather than raising them
mid-task.
