# chromium-probe-10-runs

Twenty `runtime-probe.cjs` outputs — chromium, two bench scenarios, ten runs
each — captured from one benchmark dispatch. It is the only dataset in this repo
where the same browser was measured enough times to tell a real difference from
a runner draw, and every design decision in `scripts/exec_index.py` rests on it.

## Provenance

- run [33038504763](https://github.com/jclaveau/ci-prebuilds/actions/runs/33038504763),
  2026-08-27, `benchmark-playwright.yml` on `bench/execution-index`
- dispatched `image_tag=latest` (consumer images at revision `94d3ddd5`), `runs=10`
- `alpine-dood` = `jclaveau/alpine-dood-playwright:latest`, chromium built from
  source against musl; `official` = `mcr.microsoft.com/playwright:v1.62.1-noble`,
  Chrome for Testing 151.0.7922.34 on glibc
- one file per (scenario, run); each holds the probe's own per-metric median plus
  its raw samples, and the CPU model the job landed on

## Why it is kept rather than regenerated

Regenerating costs a full `runs=10` bench (~40 min of CI across ~200 jobs), and
the questions it answers are ones you ask while *changing* the index — exactly
when you do not want a 40-minute round trip. Four things are only measurable
with n=10, and all four are asserted by `../test-exec-index.py`:

- **A ground truth that needs no correction.** The jobs landed on three CPU
  models; restricting both sides to `AMD EPYC 7763` (8 and 7 samples) gives a
  runner-free comparison, which is what any runner-correction has to be scored
  against. It reads **+15.8%**.
- **That the `int_math` normalizer was useless.** Scored against that truth,
  normalizing lands at mean |log err| 0.0083 versus 0.0085 for raw ratios — a tie.
  On the alpine side the divisor even ANTI-correlates with the CPU-bound kernels
  it stood in for (`layout` r=-0.98, `eval_rtt` r=-0.84). The normalizer was
  removed because of these numbers.

  Note what this does NOT do: re-introducing the normalizer leaves the suite
  green, because at n >= `MIN_RUNS` it genuinely changes nothing — that tie is
  the whole finding. The fixture preserves the evidence so the question can be
  re-answered in seconds; it is not a guard against the code coming back, and
  there is no defect for such a guard to catch.
- **Where the sample count converges.** Subsampling gives n=1 sd 13.1%, n=3 sd
  6.6% (worst draw +40.8%), n=5 sd 1.2%, n=10 sd 0.0%. `MIN_RUNS = 5` is read
  off this table rather than guessed.
- **That `locator_click` is frame-quantized.** 3333.x ms on both sides,
  coefficient of variation **0.0%** over ten runs each. A metric that cannot vary
  cannot discriminate, and under the old normalizer dividing that constant by two
  different CPU speeds manufactured a 1.14x gap out of nothing.

## The finding itself

alpine chromium is **~16% slower** than official, carried by `layout` **1.60x**
and `launch` **1.48x**, with `goto_warm` 1.30, `goto_cold` 1.21, `click_force`
1.14 and everything else between 1.00 and 1.11. Consistent with the residual
recorded after PGO+ThinLTO landed.

## Regenerating

```sh
gh workflow run benchmark-playwright.yml -R jclaveau/ci-prebuilds \
  --ref main -f image_tag=latest -f runs=10
# then, per artifact (the endpoint paginates — --paginate is not optional):
gh api --paginate "repos/jclaveau/ci-prebuilds/actions/runs/<id>/artifacts?per_page=100" \
  -q '.artifacts[]|select(.name|test("^runtime-probe-(alpine-dood|official)-chromium-"))|"\(.id) \(.name)"'
```

Replace the whole directory rather than adding to it: the files are only
comparable within a single dispatch, since a later one measures different images.
If you do replace it, expect `test-exec-index.py`'s figures to move — update the
numbers there and here in the same commit, and say what changed.
