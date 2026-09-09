---
name: project_perf_probe_ratio_is_cpu_dependent
description: The alpine/official ratio is itself runner-CPU-dependent, so two perf-probe runs can only be differenced when they landed on the same machine — libm_fmod is the free fingerprint that tells you
metadata:
  type: project
---

`perf-probe` puts both candidates in ONE job so the runner divides out, and that is
true *within* a run. It does **not** make two runs comparable: the ratio
itself moves with the CPU model.

The proof is `libm_fmod`, which no allocator or build flag we were testing can
touch, at CV 0.5%:

```
AMD EPYC 7763          5.35
AMD EPYC 9V74          6.24 - 6.33
Xeon Platinum 8370C    7.65
```

Cost of not knowing this: comparing a mimalloc candidate on a Xeon 8370C against a
control on an EPYC 7763 read `launch` **+0.17** and `js_alloc` **+0.13** —
both pure CPU artefacts, both gone once paired on one model. Two hours of
"did I regress launch?".

**How to use it.** Dispatch each candidate 2-3 times, read `runner.cpu` out of the
JSON (it is recorded in every file), pair candidate-to-control by CPU, and confirm
the pairing with `libm_fmod` before reading anything else. If the two
`libm_fmod` values disagree, the pairing is wrong and the rest of the table is
not a comparison. Same-model pairings agreed to ±0.09 on it.

Corollary: the standalone `perf-probe` dispatch and the inline `perf-probe`
job in `test-and-publish.yml` are different runs on different runners — a PR's
own n=1 number can only be compared against a baseline run that happened to
draw the same CPU (check before quoting it; run 33056825499 and 33064478441
both drew EPYC 7763, which is luck).

Applies to all three browser candidates, not just webkit.

**A row's rank can INVERT between models, not merely shift.** n=10 on three
CPU models each (runs 34289013835 / 34289022039 / 34289030252, 2026-09-08)
found chromium's two worst rows trading places:

```
                EPYC 9V74    EPYC 7763 (x2 replicate jobs)
layout             1.27          1.59  1.62
screenshot         1.26          1.00  1.00
```

So `libm_fmod` agreeing is necessary but NOT sufficient to quote a row across
runs — it certifies the pairing, it does not make a CPU-sensitive row
portable. Before reporting "chromium screenshot is 1.26x", say which silicon,
or draw n>=2 models. Every prior single-CPU reading of these two rows was
sampling one of two populations without knowing it.

**Sampling several models is now a script, not luck.**
`scripts/sample-cpu-models.sh --image <ref> --models 7763,9V74,8573C --draws 2`
tallies what has been collected, dispatches only the models and browsers still
short, and repeats. It is affordable because `perf-probe.yml` reads
`/proc/cpuinfo` before the checkout and image pulls, so an unwanted draw costs
~20 s instead of 10-18 min; a slot is allowed to accept a model only on the
first `ceil(need / fleet_rate)` slots, which puts a 10% model on every slot and
drops a 50% one off the tail. Full 3x3 coverage took 3 rounds, ~1 h.

**Read the per-arm scaling, not only the ratio.** `perf-report.py` now emits a
CPU-model sensitivity section: each arm against its OWN median on a reference
model. The `xoff` ratio divides the runner out and so cannot say which arm
moved; the scaling can. That is what separated chromium's CPU-independent
`launch` gap from its 7763-worst `layout` gap — see
[[project_three_model_parity_state]].

[[feedback_check_reference_stability_across_runs]] [[project_runtime_perf_probe]]
