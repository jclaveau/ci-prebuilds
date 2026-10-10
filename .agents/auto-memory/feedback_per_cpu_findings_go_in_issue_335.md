---
name: feedback_per_cpu_findings_go_in_issue_335
description: every per-CPU finding (a choice that wins on one CPU, loses on another; a CPU-dependent ratio) gets folded into issue #335's DESCRIPTION as knowledge, same turn it is measured
metadata:
  type: feedback
---

Every time a measurement shows a per-CPU difference, edit issue #335's body
(jclaveau/ci-prebuilds, "Per-CPU code selection") to add it. Edit the
description, not a comment.

**Why:** jean, 2026-10-10: per-CPU code selection is probably the last
optimization the campaign will try, and it won't start for a while. When it
does, #335 must already hold everything learned about how each CPU behaves.
Findings scattered across memories and comments get lost.

**How to apply:**
- Triggers:
  - a candidate wins on one microarchitecture and loses on another;
  - a perf-gate row ratio differs by CPU model;
  - a PMU or cycle result per CPU;
  - a CPU-gated SIGILL or feature (AVX-512, ERMS, the JCC erratum).
- Steps:
  - `gh issue view 335 -R jclaveau/ci-prebuilds --json body -q .body >| <scratch>/335.md`
  - edit the right section: cases table, not-a-split, residuals, or rules;
  - `gh issue edit 335 -R jclaveau/ci-prebuilds -F <scratch>/335.md`
- Format: `X vs Y unit (ratio)`, the CPU model, run id, and status.
- Replace a stale row instead of appending a contradiction.
- Keep the `Assisted-by: Claude:<model-id>` footer last.
- The edit counts as part of recording the result, alongside the project
  memory. It needs no ask.
- First pending entry: the V8 `%` perf-gate A/B (#333), Intel vs Zen draws.
