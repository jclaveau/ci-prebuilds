---
name: musl-mallocng-mmaps-the-driver
description: musl's mallocng maps ~64 KiB blocks straight from the kernel — 44,491 munmaps against glibc's 78 — and the allocations are node's, not the browser's
metadata:
  type: project
---

`click_force` and `eval_rtt` were the last two non-startup rows above parity on
every browser, and neither was WebKit's fault.

`perf stat -a` over one 10 s window, both arms, `eval_rtt`:

| | ours | Playwright |
|---|---|---|
| `munmap` | **44,491** | 78 |
| page-faults | 99,136 | 8,100 |
| `futex` | 7,471 | 11,967 |
| context-switches | 482,418 | 565,878 |

An `strace` histogram puts 20,866 of those munmaps at exactly **69,632 bytes**
— 64 KiB plus a page — with only **78 `clone` calls** in the same run, so they
are not thread stacks. musl's mallocng maps a block that size straight from the
kernel and returns it on free; glibc's 128 KiB mmap threshold keeps it in the
heap and never enters the kernel.

The allocations are the **node driver's**. Every browser shim already preloads
mimalloc; node was the one process left on musl malloc. Preloading it there
takes `munmap` from ~43,000 to ~1,100 over a 30 s loop, measured four times —
and removing mimalloc from the browser changes nothing, which is what pinned
it on node.

Shipped as PR #136: container-wide `ENV LD_PRELOAD=/usr/lib/libmimalloc.so.2`
plus a chromium shim that unsets it. **The shim is load-bearing, not a
courtesy** — unshielded, chromium does not start at all (`Target page, context
or browser has been closed`, 10/10).

| | metric | before | after |
|---|---|---|---|
| webkit | `click_force` | 1.15 | **1.00** |
| | `eval_rtt` | 1.10 | **0.99** |
| chromium | `eval_rtt` / `screenshot` | 1.12 / 1.15 | 1.06 / 1.08 |
| firefox | `eval_rtt` / `launch` | 0.99 / 0.94 | 0.97 / 0.93 |

The container-wide scope is not free, and jean was asked with these numbers
before it shipped: `node -e 0` startup 53.0 -> 62.8 ms (+18%), 20k x 64 KiB
`Buffer.allocUnsafe` 342 -> 681 ms and erratic, `npm install` -2%, JSON
stringify+parse -9%, RSS -13%.

**How to apply:** when a row's user CPU is at parity but its **sys** time is
higher, count syscalls, not samples — `perf stat -a -e syscalls:sys_enter_*`
over a window on the live container, divided by the container's own iteration
count. And check the DRIVER before the browser: half of what a Playwright row
measures happens in node. See [[project_wk_click_and_eval_residual]] for the
nine levers that measured flat before this one.
