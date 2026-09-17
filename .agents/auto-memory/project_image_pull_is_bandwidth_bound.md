---
name: project_image_pull_is_bandwidth_bound
description: consumer `docker pull` on a hosted runner is bytes-bound, not layer-bound — max-concurrent-downloads 3→8 moved alpine-dood-playwright 26.9→26.2 s (noise), while dropping the duplicated chromium layer (#255, 791→710 MiB gz) took it 26.9→25.0 s (−7%; −21% on jean's box where extraction dominates); a rename after the final COPY copies the whole file up into a new layer
metadata:
  type: project
---

`alpine-dood-playwright` shipped chromium's 195 MB binary twice: the LD_PRELOAD
wrapper step renamed `chrome-headless-shell` to `.real` in the final stage,
after the `COPY --from=chs-source` layer. On overlayfs a rename is a copy-up,
so the binary landed again in its own 81 MiB gz layer while the first copy sat
under a whiteout — 10% of the image was bytes consumers download and never
see. PR #255 (2026-09-17) moved the block into `browsers-staged`: 18 → 15
layers, 791.1 → 709.8 MiB gz.

**Measured with `scripts/image-pull-bench.sh` / `image-pull-bench.yml`**
(cold, bracketed, 3 rounds; run 35209283147 on ubuntu-latest):

| image | gz MiB | max-concurrent-downloads | median s |
|---|---|---|---|
| before | 791.1 | 3 | 26.9 |
| #255 | 709.8 | 3 | 25.0 |
| before | 791.1 | 8 | 26.2 |
| #255 | 709.8 | 8 | 24.3 |

- Layer parallelism is not a lever: 3 → 8 concurrent downloads is −0.7 s,
  inside the spread. Splitting the 196 MiB apk layer would buy nothing.
- Bytes are the lever, ~28 MiB/s gz effective on the runner: −10% bytes gave
  −7% wall. On jean's box the same change read −21% (22.9 → 18.1 s) because
  there extraction dominates and the dead layer was serial with the one under
  it (same file extracted twice).
- Next byte levers, unmeasured: zstd layers (−15–20% typical, needs docker
  ≥ 23 on every consumer) and the 196 MiB runtime apk layer.

**Why:** the bench exists because byte counts do not predict pull time — the
same −10% read −21% and −7% on two hosts.

**How to apply:** any layer change → dispatch `image-pull-bench.yml` with the
old and new `ghcr.io/jclaveau/<image>:sha-<sha>` refs, read the median, not
the bytes. Mutate before the final `COPY`, never after
([[project_strip_must_precede_final_copy]]).
