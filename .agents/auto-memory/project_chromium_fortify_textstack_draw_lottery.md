---
name: project_chromium_fortify_textstack_draw_lottery
description: RETRACTS the 2026-09-23 "textstack layout 1.031 is real" call — a same-runner-CPU second draw on textstack read layout 0.994 (pass); across 4 draws every breach lands on a DIFFERENT row with elevated cv on one arm, none repeats — single-draw perf-gate verdicts are runner-draw lottery, not build properties; also: fortify (#292) and textstack (#277) are not rivals, fortify's branch CONTAINS textstack's commit
metadata:
  type: project
---

Two corrections to the 2026-09-23 entries in
[[project_chromium_residual_gap_candidates]] and
[[project_perfgate_reference_arm_noise]].

**1. Not rivals — stacked.** `perf/chromium-fortify-parity` (sha `31da628`,
PR #292) contains textstack's commit `6e56156` (PR #277):
```
main
 └─ 6e56156  textstack   (PR #277)  apply-and-build.sh
     └─ 31da628  fortify (PR #292)  + Dockerfile.setup (fortify overlap-check deletion)
```
Every row tabled as "textstack loses to fortify" was really the fortify
increment measured **on top of** textstack — a valid A/B for that increment,
not a comparison of two candidates for the same slot. Promoting fortify ships
textstack too; #277 should not merge separately while #292 is open.

**2. The `layout 1.031` breach did not reproduce — different runner, not a
retest.** Textstack's gate reruns discard artifacts (rerun ≠ independent
draw), so the second draw is a fresh dispatch that happened to land on
`EPYC 9V45` instead of `EPYC 7763`:

| row | 7763 draw | 9V45 draw |
|---|---:|---:|
| layout | 1.031 ❌ | **0.994** ✅ |
| launch | 0.967 | 0.906 |
| goto_warm | 1.036 | 0.976 |
| eval_rtt | 1.025 | **1.067** ❌ |
| libm_fmod | 0.999 | **1.044** ❌ |
| geomean | 1.009 | 0.989 |

`libm_fmod` normally reads cv 0.000 flat across every 7763 draw; on 9V45 it
scattered (cv 0.030) — the same broken-single-arm signature
[[project_perfgate_reference_arm_noise]] already named for fortify's
`screenshot`/`goto_warm` breaches.

**Four draws, four different breaching rows, zero repeats:**

| draw | breached |
|---|---|
| fortify / 7763 #1 | goto_warm 1.068, screenshot 1.070 |
| fortify / 7763 #2 | — (PASS) |
| textstack / 7763 | layout 1.031 |
| textstack / 9V45 | eval_rtt 1.067, libm_fmod 1.044 |

At `runs=5` shots/row and n=1 draw, jean's ≤1.00-every-row bar is currently
decided by which runner CI hands out, not by the build. This directly
contradicts the retracted claim ("textstack is ~2.5% worse on layout as a
property of the build") — that call rested on fortify's *own* layout reading
exactly 1.000 on one draw, and fortify's second 7763 draw didn't hold that
number either (1.020).

**Fortify's second draw — PASS, best candidate yet, still not promoted.**
Parity geomean **1.003** (all rows 0.946–1.036), ratchet geomean **0.994**
(strictly better than shipped chs-latest on every row that matters:
goto_warm 0.957, layout 0.982, context_page 0.978). Gate margins say ship;
jean's ≤1.00 bar says hold — six rows sit 1.003–1.036 above it, per
[[project_perf_gate_ratchet_and_parity]]'s hard line. Not promoted.

**Self-correction, prompted by jean asking "why wasn't it 3 runs per CPU from
the beginning?":** the gate (`assert-perf-gate.py`) is a ship/no-ship
instrument, not a measurement tool, and treating its per-run ❌/✅ as a
verdict about the *build* (rather than about one draw) produced three wrong
calls in one session (textstack-vs-fortify ranking, "layout is real",
"textstack loses on 6/7 rows"). [[project_perf_probe_ratio_is_cpu_dependent]]
already said two runs can't be differenced; this is that memory's cost paid
in wall-clock. Fix path: **dispatch fresh draws, never `gh run rerun`** (a
rerun discards the prior attempt's artifacts —
[[project_perfgate_reference_arm_noise]]) — and bin them per-CPU before
reading a verdict; tooling for that shipped as PR #303,
[[project_tally_candidates_percpu_aggregation]]. Third draws for both
candidates dispatched 2026-09-23 11:16Z (fortify `35853597668`, textstack
`35853607271`) to reach n=3 per candidate; each only brings n to 2 since the
n=1 draws exist solely as parsed log tables, not cached artifacts.

**How to apply:** never call a single perf-gate draw a build property. Before
ranking or retiring a chromium candidate on a breach, dispatch (not rerun) at
least one more draw and check `tally.py`'s per-cpu/global/fleet geo
(PR #303) — a row that breaches once and passes on a redraw is runner
lottery, not signal.

**n=2 aggregate, 2026-09-23 — `nav` is now the whole residual, not noise.**
Both candidates' second EPYC 7763 draw landed, giving the first real
per-cpu-geo reading (PR #303's own aggregation, not a raw single draw):

| candidate | startup | nav | render | js | input | geo |
|---|---|---|---|---|---|---|
| fortify `31da628` 7763 n=2 | 0.99~ | **1.04, breached 2/2** | 1.00~ | 1.01~ | 1.02~ | 1.01 |
| textstack `6e56156` fleet n=2 | 0.98 | **1.03, breached 1/2** | 1.01~ | 1.00~ | 1.02~ | 1.01 |

`chs-latest` (shipped) on the same runners reads `nav` 1.06-1.08, so both
candidates already beat promoted — but neither clears jean's ≤1.00 bar.
Unlike the earlier 4-draw table (breaches scattered, no row repeating),
`nav` is now the row that keeps breaching across draws while startup /
render / js / input read at or under parity for both candidates. Read this
as the campaign's real open row, not as more lottery noise — the opposite
of the draw-lottery finding above for `layout`/`eval_rtt`/`libm_fmod`. Two
more draws each dispatched (fortify `35856226276 35856236047`, textstack
`35856245089 35856255061`) to reach n=4 and confirm `nav` holds.

**n=4 aggregate, 2026-09-23 — `nav` holds, no longer lottery.** 3 of the 4
new draws read `failure`, all breaching on `nav` alone:

| candidate | cpu | n | startup | nav | render | js | input | geo |
|---|---|---|---|---|---|---|---|---|
| fortify `31da628` | EPYC 7763 | 4 | 0.97 | **1.04, 4/4 breached** | 1.00~ | 1.01~ | 1.02~ | 1.01 |
| textstack `6e56156` | fleet | 4 | 1.00 | **1.04, 3/4 breached** | 1.01~ | 1.01~ | 1.03~ | 1.02 |
| `chs-latest` (shipped), same jobs | — | — | 0.96–1.00 | 1.04–1.08 | 1.00~ | 1.01~ | 1.01–1.14 | 1.01–1.02 |

Both candidates still beat promoted `chs-latest` on `nav` but neither
clears jean's ≤1.00 bar. `nav` at 4/4 on fortify is the first row in this
whole file to repeat across every draw instead of scattering — the
distinction from `layout`/`eval_rtt`/`libm_fmod` above is now settled:
those were single-draw noise, `nav` is a build property. One bright spot:
textstack on EPYC 9V45 reads geo **0.98**, nav 0.97 — under parity on that
silicon, so the residual may be CPU-model-dependent too. Neither candidate
promotes; nothing left to gain from more draws on this pair — the next
instrument is a profile of `nav`/`click_force`, not another gate draw
([[project_chromium_click_force_never_profiled]]).
