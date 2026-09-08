---
name: wk-skia-cpu-rendering
description: WEBKIT_SKIA_ENABLE_CPU_RENDERING=1 ships — three rows move, two cross below parity; the composition twin is inert
metadata:
  type: project
---

On this image "GPU" means llvmpipe, so WebKit painting through a GL context is
painting on the CPU with a round trip added. The click profile showed llvmpipe
at 1.89x the CPU per iteration and a `SkiaGPUWorker` thread we had and
Playwright did not.

`WEBKIT_SKIA_ENABLE_CPU_RENDERING=1`, in the webkit `pw_run.sh` wrapper so it
stays off the Node driver and the other two browsers (PR #181). Measured three
times at n=10, arm and control on one runner each time:

| metric | before | after |
|---|---|---|
| `goto_cold` | 1.07 / 1.13 | **0.89 / 0.92 / 0.90** |
| `goto_warm` | 1.01 / 1.01 | **0.90 / 0.91 / 0.89** |
| `context_page` | 0.97 / 0.94 | 0.91 / 0.89 / 0.90 |

Nothing regressed, and conformance-webkit is green on the same artifact with
the same variable (run 34184981149). `pw-conformance.yml` sets it too — a
raster change conformance does not exercise is a raster change nobody tested.

**Inert twin:** `WEBKIT_USE_SKIA_FOR_COMPOSITION=1` on top of it measured flat
on every row (click_force 1.20 vs 1.21, n=10, one runner). The `SkiaGPUWorker`
thread does disappear with CPU rendering, but llvmpipe stays at ~11.3% of
samples against Playwright's 9.3% — compositing still goes through GL and no
env var found so far takes it off.

**How to apply:** the WebKit env knobs are discoverable with
`strings libWPEWebKit-*.so.1 | grep -oE 'WEBKIT_[A-Z0-9_]+' | sort -u` — but
read the whole list, the `WEBKIT_SKIA_*` family sorts after a long run of
`WEBKIT_GST_*` and a `head` misses it. See
[[project_wk_launch_is_mesa_in_the_closure]] for the other half of the Mesa
story.
