---
name: wk-click-and-eval-residual
description: click_force 1.20 and eval_rtt 1.09 are CPU-bound and diffuse — nine env knobs, the allocator's purge policy and the string routines all measured flat
metadata:
  type: project
---

After `launch`, `goto_cold` and `goto_warm` were fixed, these two are what is
left above parity. Both are **CPU-bound, not wait-bound**: children's user+sys
CPU per iteration tracks throughput almost exactly (alpine 0.481 s/round at 134
rounds vs official 0.441 at 145; second rep 0.496 vs 0.478). So the ~50% idle
in their profiles is not the story.

Curiously, alpine's **user** time is LOWER (50.3-50.5 s vs 51.7-52.7) and its
**sys** time higher (13.9-14.1 vs 12.2-12.4).

Everything tried, all flat:

| lever | result |
|---|---|
| `WEBKIT_USE_SKIA_FOR_COMPOSITION` | flat, n=10 on one runner |
| `WEBKIT_DISABLE_DMABUF_ATLAS` | flat |
| `WEBKIT_LAYERS_TILE_SIZE` 512 / 2048 | flat |
| `WEBKIT_FORCE_VBLANK_TIMER` | flat |
| `WEBKIT_SKIA_CPU_PAINTING_THREADS=4` | flat |
| CPU rendering OFF | flat (it only moves the goto rows) |
| `MIMALLOC_PURGE_DELAY` -1 / 10000 | flat |
| `MIMALLOC_ARENA_EAGER_COMMIT` | flat to slightly worse |
| AVX2 string preload | flat, see [[project_wk_string_routines_inert]] |

The resolved profile is diffuse: the largest WebKit symbol is
`JSONImpl::decodeString` at 0.31% of all samples, followed by the JSON
tokenizer, `Value::operator delete`, `WTF::fastFree`, `fastMalloc` and
`pas_thread_local_cache_flush_deallocation_log`. Nothing to aim at.

**Open thread:** an `strace -c -f` over an eval_rtt loop showed alpine at
~2.6x official's `mmap` per round and far more `munmap`, which would fit the
extra sys time — but the official arm's trace also carried 350 `clone` and 369
`execve` calls that ours did not, so the two traces are not clean counterparts.
Re-run with a quiet official arm before trusting the ratio.

**How to apply:** the WebKit-side arms for these rows are exhausted at the env
level. What is left is build-level (compiler version, `USE_SYSTEM_MALLOC` with
the mimalloc preload) or Mesa-level (ours is 26.1.6, Playwright's 25.2.8), and
each of those is a multi-hour build — price the win first.
