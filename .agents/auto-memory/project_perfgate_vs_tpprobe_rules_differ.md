---
name: project_perfgate_vs_tpprobe_rules_differ
description: perf-gate (promote) and TP's perf-probe (per-PR) disagreeing on the same row is BY DESIGN, not a bug — different margins, different pass/fail axis, different geomean grouping; found a dead-code bug in assert-perf-gate.py's margin_for(), but the intended fix (swap precedence) is WRONG — correct fix was deleting firefox's loose entries entirely, SHIPPED as PR #312 2026-09-24 (launch 1.10 -> 1.06, js_alloc unchanged); webkit's loose rows still blocked on a non-skipped perf-gate-webkit
metadata:
  type: project
---

2026-09-24: asked why firefox shows a perf delta between "build perf tests"
(TP's `perf-probe`, per-PR) and "main perf tests" ([[project_perf_gate_ratchet_and_parity]]'s
`perf-gate`, promote-time). Two different things were conflated; neither
harness was lying.

**They assert different things, deliberately:**
- `perf-gate` checks parity (`candidate/official`) **and** ratchet
  (`candidate/promoted`), both at 1.00 + a tight per-row margin
  (`perf-gate-margins.json`, ~3% on tight rows). Hard-fails, blocks promote.
- TP's `perf-probe` asserts `perf-budgets.json` ceilings, deliberately not
  parity — its own docstring says gating on parity "would paint main red by
  coin flip" ([[parked_perf_budget_gate_design]]'s original reasoning).
  `continue-on-error: true`, not a merge blocker. Firefox `js_alloc`: gate
  ceiling **1.03**, TP budget **2.30** — almost two orders apart on purpose.
- TP also reports **grouped** geomeans (e.g. `js 0.94`), which can swallow a
  single row reading 1.065 that the gate's per-row check would catch.

**Match epoch + CPU and they agree to two digits** — gate `render 0.58`, TP
`render 0.59`, once both are read from the same build epoch. A raw
side-by-side without controlling for epoch will look like disagreement that
isn't there; see [[project_ff_perfgate_js_alloc_screenshot_breach]] for the
concrete instance (a stale pre-PGO gate run vs a post-PGO TP reading).

**Dead-code bug found while comparing them:** `perf-gate-margins.json` lists
firefox `js_alloc` under `loose` (margin 0.10), but `margin_for()` in
`assert-perf-gate.py:57` checks `tight` first, and `js_alloc` is *also*
listed in `tight.rows` — so the per-browser `loose` exception never applies
and the row is always judged at the tight 0.03 margin.

**Ruling reversed 2026-09-24** (jean, on hearing "swap precedence" was the
plan: *"It loosens the promote gate enabling promoting a more performant
build? That's odd to me"*). Checked the gate's own CV column on both the
red and green ff `js_alloc` runs:

| run | js_alloc ratio | ceiling | cv cand | cv ref |
|---|---:|---:|---:|---:|
| 799bdf7 (red, pre-PGO) | 1.065 ❌ | 1.03 | 0.014 | 0.014 |
| 04dde38 (green, post-PGO) | 0.981 ✅ | 1.03 | 0.009 | 0.017 |

Shot-to-shot noise is 1-1.7%. A 1.03 ceiling is ~2x CV — correctly sized.
The 1.065 breach was a REAL 6.5% regression, correctly caught by the tight
margin the dead code accidentally left in force. **The bug's accidental
effect was right; only the documented intent (that firefox `js_alloc`
needed the looser margin) was wrong.** `perf-gate-margins.json`'s `loose`
list was copied from `perf-budgets.json`'s reasoning — cross-run,
cross-CPU-model dispersion — but `perf-gate` structurally doesn't have that
axis: 3 arms, 1 job, 1 runner. That reasoning doesn't transfer.

**Correct fix is the opposite of the original proposal: delete firefox's
`js_alloc` AND `launch` from `loose` entirely, do not swap tight/loose
precedence.** `launch`'s worst observed CV is 0.042 — already covered by
the 0.06 default; the 0.10 loose margin is 2.4x its noise, pure slack.
Webkit's `eval_rtt`/`click_force` loose entries can't be judged the same
way yet — every `perf-gate-webkit` job checked was `skipped`, no CV data
exists for them.

**SHIPPED as PR #312** (`perf/ff-gate-margins`, fa16569, 2026-09-24), on
jean's go once the firefox half stopped being blocked on webkit: the two
halves are independent, and `launch`'s CV had three draws behind it by then
(0.042 / 0.028 / 0.018 cand-side, gate jobs 107321907380 and 107471034822).
The whole `"firefox"` key comes out of `loose`; `js_alloc` is unchanged at
1.03 because `tight` already won, `launch` goes 1.10 -> the 1.06 default.
`margin_for` itself is untouched — `margins["loose"].get(browser, [])`
already handles a browser with no entry.

Webkit's `eval_rtt` / `click_force` stay in `loose` and stay blocked: every
`perf-gate-webkit` job checked still reads `skipped` (it needs
`[build-webkit-finalize, smoke-webkit]`, so it only runs on an actual webkit
rebuild), so there is no CV column to size them from.

**How to apply:** don't try to reconcile a gate-vs-TP-probe disagreement by
assuming one of them is wrong — check build epoch/CPU match first, check
which one is doing per-row vs grouped geomean, and only then treat a
remaining gap as real. When touching `assert-perf-gate.py`'s margin lookup:
the fix is deleting the firefox `loose` entries, NOT swapping tight/loose
precedence — check a row's actual CV against its ceiling before assuming a
margin is mis-sized in either direction. A margin should track its own
harness's noise (same-job CV here), not get copied from a different
harness's reasoning (cross-CPU dispersion, which `perf-budgets.json`
legitimately has and `perf-gate` does not).
