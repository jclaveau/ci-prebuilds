---
name: project_chromium_musl_string_routines
description: official chromium carries its own memcpy/memcmp/strlen; ours calls musl's, which are 3-30x slower in the sizes layout uses — leading candidate for the residual gap
metadata:
  type: project
---

`nm -D` on the two `chrome-headless-shell` binaries, run **32505115445**:

| symbol | ours (alpine) | official (noble) |
|---|---|---|
| `memcpy` `memmove` `memset` `memcmp` `strlen` | undefined=1 | undefined=0 **and** defined=0 |

Official does not reach libc for any of them — they are resolved inside the
binary. Ours routes every one through the PLT into musl. Not a musl-vs-glibc
comparison at all: it is musl against whatever Chromium's own toolchain emits.

And musl's are slow in the sizes layout works in (`libc-string-bench.c`, same
source, same `-O2 -fno-builtin`, both containers, one runner):

| ratio musl/glibc | 16 B | 64 B | 256 B | 1 KB | 4 KB | 64 KB | 1 MB |
|---|---|---|---|---|---|---|---|
| `memcpy` | 2.18 | 3.47 | 3.69 | 3.72 | 3.96 | 1.00 | 1.20 |
| `memmove` | 1.94 | 3.53 | 4.72 | 6.07 | 5.50 | 2.07 | 1.47 |
| `memcmp` | 4.03 | 8.43 | 24.61 | 27.66 | 30.06 | 20.95 | 10.36 |
| `strlen` | 3.89 | 3.86 | 4.23 | 5.68 | 7.34 | 4.61 | 4.63 |
| `memset` | 1.03 | 2.19 | 3.31 | 2.00 | 1.04 | 1.00 | 1.00 |
| `nop` (loop cost) | 1.06 | 1.13 | 1.12 | 1.03 | 1.03 | 1.50 | — |

`nop` near 1.0 is what lets the two gcc versions off the hook. Alpine has no
IFUNC, so musl links one scalar implementation where a dispatching libc picks
an AVX2/ERMS variant off the CPU at load.

**The `typed_array_move` / `typed_array_fill` kernels are INERT** — 1.01x both.
V8 lowers TypedArray copies to its own loops and never calls libc, so they
discriminate nothing. Do not read their parity as evidence against this.
[[feedback_prove_the_lever_is_connected]]

`layout_boxonly` vs official: 1.57x (32502670597), 1.60x (32505115445) —
stable. `layout_text` 1.53x then 1.36x — wobbly, footnote only.

**How to apply:** the open question is whether Blink's layout hot path actually
spends there. The one-variable test is `LD_PRELOAD` of an AVX2 implementation
into our own binary, re-running `layout_boxonly` — same binary, same fonts,
same allocator. If confirmed, the shipping fix is build-side (make Chromium
emit or link its own routines) and NOT a musl swap. Related:
[[project_chromium_residual_gap_candidates]],
[[project_alpine_browser_perf_vs_glibc]].
