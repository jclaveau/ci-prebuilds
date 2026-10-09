---
name: project_ff_fortify_off_result
description: FF fortify-off (perf/ff-fortify-off, run 35993882679) RESOLVED as a REAL lever, not void — same-job ratchet vs promoted fi-latest reads geomean 0.972 (screenshot 0.889, layout 0.942), pure-compute controls flat at 1.000; the mozbuild flag-order worry (MOZ_HARDENING_CFLAGS re-enabling _FORTIFY_SOURCE=2) did not happen
metadata:
  type: project
---

Candidate from [[project_chr_levers_missing_from_ffx_wk]]'s #2 finding: FF
builds with packaged `clang23` and never neutralizes Alpine's forced
`_FORTIFY_SOURCE=2`, unlike WebKit ([[project_webkit_fortify_source_skia_trap]])
and unlike chromium's own fix for the same class of tax
([[project_chromium_nav_gap_is_musl_fortify_overlap_check]] — musl fortify's
inline memcpy overlap check inside Skia raster). Branch `perf/ff-fortify-off`
sets `CFLAGS` default to add `-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0` and
asserts a compiler-level fortify probe (`ud2` trap count) at 0 before
building.

**Known risk going in:** Mozilla's own build emits both
`MOZ_HARDENING_CFLAGS = ... -D_FORTIFY_SOURCE=2 ...` and
`MOZ_OPTIMIZE_FLAGS = ... -D_FORTIFY_SOURCE=0`, and the compiler probe only
tests `$CC $CFLAGS` standalone — it cannot see whether Mozilla's own hardening
flags re-add `=2` later on the real command line and override ours. Held the
verdict for the perf-gate rather than trusting the probe.

**RESULT, run 35993882679 (2026-09-24), all green:** decisive number is the
same-job ratchet — candidate vs promoted `fi-latest`, same runner, same draw:

| row | cand/promoted |
|---|---:|
| screenshot | 0.889 (−11%) |
| layout | 0.942 (−6%) |
| launch | 0.946 |
| context_page | 0.954 |
| goto_warm | 0.962 (inside noise) |
| goto_cold | 0.978 |
| dom_churn | 0.980 |
| int_math / libm_fmod / js_alloc / locator_click / click_force | 1.000 flat |

**Why this rules out runner luck, not just noise:** the pure-compute rows
(int_math, libm_fmod, js_alloc — libc/JIT-bound, no memcpy) sit at exactly
1.000 while the memcpy-heavy rows (screenshot = PNG encode, layout = Skia)
move. Runner luck would move everything, not a selected subset that matches
the mechanism. Same lever shape as chromium PR #273. **Verdict: mozbuild flag
order held — `OS_COMPILE_CFLAGS` precedes `OPTIMIZE`, our `=0` won, `=2`
never reached the compile line.** vs official geo 0.757, inside the shipped
FF spread (0.74–0.78) — which is why reading only the vs-official view (not
the ratchet) made the arm look void at first glance.

**Gate verdict: PASS — faster than official, no slower than promoted.** Not
yet merged as of session end; still sitting on `perf/ff-fortify-off`.

**How to apply:** when a candidate's vs-official number lands inside the
noise of what's already shipped, don't conclude "void" from that view alone
— draw the same-job ratchet against the currently-promoted build first. A
flat control set (rows the mechanism shouldn't touch) sitting at exactly
1.000 while the targeted rows move is the tell that the effect is real, the
same check [[project_ff_pgo_arm_mechanics]]'s `int_math`/`libm_fmod`/
`locator_click` control used.
