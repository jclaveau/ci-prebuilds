---
name: project_perf_probe_ratio_is_cpu_dependent
description: The alpine/official ratio is itself runner-CPU-dependent, so two perf-probe runs can only be differenced when they landed on the same machine — libm_fmod is the free fingerprint that tells you
metadata:
  type: project
---

`perf-probe` puts both arms in ONE job so the runner divides out, and that is
true *within* a run. It does **not** make two runs comparable: the ratio
itself moves with the CPU model.

The proof is `libm_fmod`, which no allocator or build flag we were testing can
touch, at CV 0.5%:

```
AMD EPYC 7763          5.35
AMD EPYC 9V74          6.24 - 6.33
Xeon Platinum 8370C    7.65
```

Cost of not knowing this: comparing a mimalloc arm on a Xeon 8370C against a
control on an EPYC 7763 read `launch` **+0.17** and `js_alloc` **+0.13** —
both pure CPU artefacts, both gone once paired on one model. Two hours of
"did I regress launch?".

**How to use it.** Dispatch each arm 2-3 times, read `runner.cpu` out of the
JSON (it is recorded in every file), pair arm-to-control by CPU, and confirm
the pairing with `libm_fmod` before reading anything else. If the two
`libm_fmod` values disagree, the pairing is wrong and the rest of the table is
not a comparison. Same-model pairings agreed to ±0.09 on it.

Corollary: the standalone `perf-probe` dispatch and the inline `perf-probe`
job in `test-and-publish.yml` are different runs on different runners — a PR's
own n=1 number can only be compared against a baseline run that happened to
draw the same CPU (check before quoting it; run 33056825499 and 33064478441
both drew EPYC 7763, which is luck).

Applies to all three browser arms, not just webkit.
[[feedback_check_reference_stability_across_runs]] [[project_runtime_perf_probe]]
