---
name: project_shipped_geo_pooled_across_promote
description: tally's shipped-browser geo used to pool every draw in the scan window, so it averaged across a promote and a shipped win took ~6 main chains to appear — firefox read 0.83 for days when the promoted PGO build was 0.76; fixed by cutting at the last promote (PR #314); the residual over-cut is a re-promote of a cache-hit build
metadata:
  type: project
---

**A shipped-browser geomean is only readable if every draw in it measured the
same browser build.** `tally.py`'s shipped blocks pooled all six draws in the
scan window, and `promote-<browser>` moves `<browser>-latest` mid-window, so
the pool straddled the promote.

Firefox, 2026-09-24, is the worked case. PGO promoted 09-23 (PR #285):

```
6853c79 0.93  a476258 0.94   <- pre-PGO draws, still pooled
7c329f7 0.79  355756e 0.75  6e70458 0.77  d2f0ff9 0.81
global geo 0.83              <- what tally printed for days
```

The gate said the same build was **0.75**, `fi-latest` 0.76 in the same job.
Two instruments disagreeing by 0.08 looked like a real instrument effect
(n=1 TP shots vs n=5 gate shots, CPU mix) and it was not — it was two stale
draws in one average. **Cutting at the promote makes them agree: 0.77 global
/ 0.76 fleet vs the gate's 0.75/0.76.**

Fixed in **PR #314** — `last_promotes()` reads the newest successful promote
per browser from the build workflow's `promote-<browser>` job and from the
standalone `promote-*.yml` dispatches; older draws stay listed marked
`pre-promote` and are excluded from every geo; the block title names the cut
and the draw count.

**Residual, deliberate:** `promote-<browser>` also runs when the build was a
registry cache hit, so a re-promote of an unchanged image still cuts and
costs draws (firefox's `7c329f7` 0.79 is marked `pre-promote` though its
`build-firefox` ran 2m05). Conservative direction — it never pools across a
build change. Telling the two apart needs the promoted digest: 5349 package
versions, ~24s per `--paginate`, and the `sha-` tag is shared by all three
browsers in the bundle so its digest cannot attribute a change to one of
them. A duration threshold is not a substitute — it would have to differ per
job (`build-firefox` cache hit 2m05 vs `build-webkit-finalize` real 9m07).

**How to apply:** never quote a shipped geo without knowing how many draws
it read and when the last promote was — the title now says both. Same class
of trap as [[project_perf_probe_ratio_is_cpu_dependent]] (a pooled number
whose members are not comparable), and the reason
[[feedback_tally_is_the_script]] says to relay tally rather than
hand-assemble the average.
