---
name: project_wk_launch_is_the_loader
description: WebKit's launch 1.33 is not our build's shape — ours has FEWER relocations and a SMALLER .text than official yet dlopens slower; BIND_NOW and DT_RELR are both exonerated by measurement, so the remaining suspect is musl's dynamic loader
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

**Not relocation PROCESSING either — `DT_RELR` measured and verified applied.**
A cold arm linked with `-Wl,-z,pack-relative-relocs` cut the dynamic
relocations 21x, and `launch` did not move:

```
                       RELR arm      shipped
relocation entries       15,064      320,694
has .relr.dyn                 1            0
launch (x official)        1.42         1.44
```

Verified end-to-end on the CONSUMER image that was probed
(`alpine-dood-playwright:sha-25531bd6`), not on the build log — the same
standard the stack-protector arm was held to. Caveat worth carrying: that arm
was built before ThinLTO landed (`.text` 106.4 MB against the shipped 92.0),
so both sides read ~1.4 and the comparison is only good for the RELR question
it was built to answer. It answers it: whatever `launch` is paying for, it is
not walking the relocation table.

**Not BIND_NOW**, though ours links it and official does not (ours carries
`FLAGS BIND_NOW` + `FLAGS_1 NOW`; official's dynamic section has neither). A
within-binary A/B on OFFICIAL — `RTLD_NOW` vs `RTLD_LAZY` via dlopen, which
holds every build difference fixed — showed no cost for eager binding; its
`NOW` runs were if anything faster than its `LAZY` ones, i.e. noise dominates
the effect. Only ~3,150 PLT entries separate the two modes, so this was always
a small candidate. Note `RTLD_LAZY` is INERT on our lib: `DF_1_NOW` in the
object overrides the dlopen flag, so ours cannot be A/B'd this way at all.

**The profile, and what it did and did not settle.** A launch-kernel profile
(`wk-perf-record.yml`, kernel `launch`) resolves BOTH arms — processes that
start inside the recording window emit live mmap events, so it never needed
the /proc synthesis that fails for a root-owned container under an
unprivileged perf. Top DSOs, share of ALL samples:

```
alpine                            official
10.34%  ld-musl-x86_64.so.1        8.82%  ld-linux-x86-64.so.2
 2.28%  libgcc_s.so.1              0.80%  libc.so.6
```

Ours clusters in ~200 bytes at 0x37100-0x371c9, which `musl-dbg` resolves to
**`gnu_lookup_filtered`** — symbol lookup — at ~5.2% of all samples against
official's ~3.5% loader cluster.

**Eager binding is NOT the cost.** Alpine links `-z now` by default and PW's
build carries neither DF_BIND_NOW nor DF_1_NOW, which made this look decided.
Clearing both bits on all 22 bundle ELFs needs no rebuild (the PLT stubs are
emitted either way), and the arm — verified on the published image, "no
eager-binding flags", 0 unresolved deps — measured FLAT: launch 1.44 shipped
against 1.45 lazy, every other row within noise, n=10 on one Xeon 8370C. So
the lookups being paid are the ones actually needed and the cost is PER
LOOKUP, not per symbol table. See `playwright/bench/clear-bind-now.py` and
`wk-lazy-bind-arm.yml` if the question comes back.

**Still open from the same profile:** libgcc_s at 2.28% against official's
<0.17% — 13x more DWARF unwinding, hot in the static CFI machinery past
`_Unwind_Backtrace`. `run-unwind-probe.sh` counts throws and walks separately
because those two want opposite fixes.

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
