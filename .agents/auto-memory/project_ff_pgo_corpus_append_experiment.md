---
name: project_ff_pgo_corpus_append_experiment
description: 2026-09-23 testing whether training PGO on the graded workload moves anything — append runtime-probe.cjs's kernels to Mozilla's own PGO corpus (PR #307, run 35913494826, branch firefox/pgo-probe-corpus); RESULT B is a WASH (ratchet geomean 0.995 then 1.001 over two draws, both breaching a different row inside its own cv; profile check confirmed the probes trained, +26.4% total count); #307 CLOSED 2026-09-24 on jean's ruling, branch kept for reference; arm C moot; int_math/libm_fmod held out as controls; structurally CANNOT read click_force (FF's worst row, CDP-level); evidence for the chromium self-PGO decision, not a firefox fix
metadata:
  type: project
---

Grew out of jean asking what [[project_ff_pgo_arm_mechanics]]'s 0.74 win
implies for chromium's self-PGO decision
([[project_chromium_three_levers_dispatched_parallel]]): FF self-generates
its profile but trains on Mozilla's own `mach` profileserver corpus, not on
the kernels the campaign is graded on. If "train on the graded workload" is
the real lever, FF is the cheap (6h05, already-plumbed) place to test
whether that claim is even true, before spending chromium's revised ~effort
on the same idea. Jean: "I see no reason not to try retraining FF on probe
kernels if it provides good insight."

**Why append, not replace.** Mozilla's corpus (`build/pgo/index.html`) is 70
talos reftests + sunspider + Speedometer3 + webaudio, each opened 2s then
`Quitter.quit()`. `-fprofile-use` treats zero-count functions as cold and
optimizes them for size, so a straight one-page replacement would very
likely come back *worse* — and that result is uninterpretable, since
"workload-training doesn't help" and "our corpus is too narrow" would
produce the identical number. Appending holds coverage constant so only one
variable moves.

**3-arm design:**

| arm | corpus | cost | status |
|---|---|---|---|
| A | Mozilla's, as shipped | already have it — geo 0.74 | done |
| B | Mozilla's **+** our probe page | ~6h05 + gate | done, `35913494826` — wash |
| C | probe page alone | only worth building if B moves something | not started |

B vs A is single-variable with coverage held constant. C alone would have
been the ambiguous arm (same problem as a straight replacement).

**What B can and cannot read.** Content-bound rows reachable from a page the
profileserver opens with `window.open`: `layout`, `dom_churn`, `goto_warm`,
`eval_rtt`, `js_alloc`. **Cannot read** `launch`, `context_page`,
`screenshot`, `click_force`, `locator_click` — CDP/process-level, structurally
unreachable from an in-page corpus entry. FF's worst row, `click_force`
(1.000), is in that unreachable set — this experiment cannot fix it. It is
evidence for the chromium decision, not a firefox improvement in itself.

**Controls held out.** `int_math` and `libm_fmod` are excluded from the
corpus deliberately — they're the rows that stayed pinned at 0.86 in the
original PGO gate and made the 0.74 credible as a real effect, not codegen
noise. Training on them would spend the experiment's only negative control.

**Verification moved to the profile, not the page.** Local browser
validation of the corpus page was blocked by this box (chromium GPU process
crash-loops on `pcilib`/dbus/KWallet noise — a desktop-env issue, not a
corpus bug, not worth fighting). The real failure mode isn't a hang anyway:
`Item.run` closes the subwindow at its own timeout regardless, so a wedged
corpus entry can't stall the build — it silently contributes zero profile
counts and looks identical to success from outside, making the eventual
gate number meaningless. Fix: the generate stage now prints
`llvm-profdata show` on `merged.profdata` and that summary is checked
against main's baseline *before* the 2h41 use build is worth reading at all.

**What shipped (PR #307):** `firefox/pgo-corpus/build-corpus.cjs` generates
the corpus FROM `runtime-probe.cjs` (trained pages and graded kernels can't
drift apart); `firefox/pgo-corpus/{index,probe}.html` generated output, the
iframe re-navigated 8× so the parse/load path `goto_*` measures gets
trained too, not just in-page work; `firefox/scripts/apply-and-build.sh`
appends one `items.push(...)` line into Mozilla's `build/pgo/index.html`
and asserts it landed exactly once (same idiom as `musl-source-fixes.sh`);
`Dockerfile` gets one `COPY firefox/pgo-corpus`.

Dispatched `35913494826` (branch `firefox/pgo-probe-corpus`), generate stage
in_progress. ETA generate ~23:27Z, use ~02:08Z, gate ~02:25Z (04:25 Paris).

**How to apply:** if this arm's gate number lands, compare its per-row
geomean directly against [[project_ff_pgo_arm_mechanics]]'s A-arm table —
any of `layout`/`dom_churn`/`goto_warm`/`eval_rtt`/`js_alloc` moving beyond
noise is the signal that answers the chromium question; `launch`/
`context_page`/`screenshot`/`click_force`/`locator_click` are not expected
to move and a move there would mean something else changed, not the corpus.

**RESULT, 2026-09-24: B is a wash — the retrain bought nothing.** Run
`35913494826` completed green (generate 3h30, use ~2h37, conformance-firefox
green) and the gate was drawn twice. The profile check passed first:
`merged.profdata` pulled out of both `ff-pgo-profile-sha-*` images and read
with `llvm-profdata` 23 (local 20 refuses — "unsupported instrumentation
profile format version"), baseline `56d0a9c` = the `firefox/pgo-arm` tip this
branch sits on. Total functions and blocks identical (405142 / 2584216, same
binary), but **Total count 60.94G → 77.00G (+26.4%)** and **max internal block
count 322.7M → 617.8M (+91%)**: the probe kernels contribute 21% of all merged
counts, so they ran and did *not* wedge — the timeout failure mode this file
predicted did not happen.

The gate, ratchet vs promoted `ff-latest`:

| row | draw 1 | draw 2 |
|---|---:|---:|
| **geomean** | **0.995** | **1.001** |
| context_page | 1.063 ❌ | 1.001 ≈ |
| goto_cold | 1.051 ≈ | 1.068 ❌ |
| dom_churn | 0.913 ✅ | 0.919 ✅ |
| layout | 0.961 ✅ | 0.983 ✅ |
| launch | 0.971 ✅ | 0.999 ✅ |
| parity geomean | 0.800 ✅ | 0.779 ✅ |

Both draws BREACH, never on the same row, each breach smaller than that row's
own cv (context_page 0.003 over on cv 3.8/5.1%; goto_cold 0.008 over on cv
4.6/3.5%) — the draw lottery, not a regression. `dom_churn` −8% and `layout`
−2…−4% are the only repeatable wins and they are paid back by drift on the
navigation rows. **PR #307 CLOSED 2026-09-24**, jean's ruling on the null
result; branch `firefox/pgo-probe-corpus` kept for reference.

Reading draw 2 alone invites a wrong story — `goto_cold` 1.068 is 2.6 se out
as a ratio of two n=5 means, which looks exactly like the profile-weight trade
you would predict from training on micro-kernels. It is not: draw 1 has
`goto_cold` green and `context_page` breaching instead. **Two draws are the
minimum before attributing a breach on this gate**; the breach row is not
stable across them.

Two things this settles. First, `perf-gate-firefox` **does** redraw on a
single-job rerun — it probes in-job at step 6 and downloads no sibling
artifact, unlike `perf-report` ([[project_gh_run_rerun_single_job]]). Second,
and the reason the experiment existed: training on the graded workload is
**not** the lever. Chromium self-PGO's foreign-hash rationale was already
measured dead (0.0% of counts dropped,
[[project_chromium_three_levers_dispatched_parallel]]), and workload fit was
its last remaining case — tested here as directly as it can be tested, for a
geomean of 1.00. Arm C (probe page alone) is moot: it was gated on B moving
something.
