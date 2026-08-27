---
name: project_wk_launch_is_the_loader
description: WebKit's launch 1.33 is not our build's shape — ours has FEWER relocations and a SMALLER .text than official yet dlopens slower; BIND_NOW is exonerated by a within-binary A/B, so the remaining suspect is musl's dynamic loader
metadata:
  type: project
---

`launch` is the one metric the mimalloc preload did not move (1.29-1.37 ->
1.31-1.35 across three same-CPU pairings). What it is NOT, measured:

**Not the DSO closure** — the thing that explains chromium's launch gap
([[project_chromium_launch_dso_closure]]). Ours is the LEANER side:

```
                       ours    official
libWPEWebKit DT_NEEDED   60          70
MiniBrowser  DT_NEEDED   16          74
```

**Not relocation count, and not library size.** Ours is smaller on both axes
and still loads slower:

```
                       ours          official
.text                  91.9 MB       98.6 MB
relocation entries     320,694       339,342
RELACOUNT (RELATIVE)   313,989       332,177
dynamic symbols          4,036         3,955
```

**Not BIND_NOW**, though ours links it and official does not (ours carries
`FLAGS BIND_NOW` + `FLAGS_1 NOW`; official's dynamic section has neither). A
within-binary A/B on OFFICIAL — `RTLD_NOW` vs `RTLD_LAZY` via dlopen, which
holds every build difference fixed — showed no cost for eager binding; its
`NOW` runs were if anything faster than its `LAZY` ones, i.e. noise dominates
the effect. Only ~3,150 PLT entries separate the two modes, so this was always
a small candidate. Note `RTLD_LAZY` is INERT on our lib: `DF_1_NOW` in the
object overrides the dlopen flag, so ours cannot be A/B'd this way at all.

**What is left.** A raw `dlopen` of the two libraries, best-of-8 on one box:
ours ~84 ms, official ~56 ms — a ~28 ms gap that is the right size for the
launch delta (98.6 vs 74.1 ms on the probe). Since ours has fewer relocations
and less text, the per-relocation cost differs, which points at musl's dynamic
loader rather than at anything in our build. Treat as a LEAD, not a finding:
the box was loaded and official's spread was 55.8-133 ms.

To settle it properly, run the dlopen bench on a quiet runner, and note the
`ubuntu` probe arm CANNOT decide this — it is a glibc container running PW's
own binary, so it holds neither the loader nor the build fixed.

Also ours-only: `USE_LIBBACKTRACE=OFF` (official ships `libbacktrace.so.0` in
`minibrowser-wpe/sys/lib/`), and our layout is flat with `RPATH=$ORIGIN` while
official splits `bin/`, `lib/` and `sys/lib/`
([[project_wk_artifact_flat_lib_layout]]).
