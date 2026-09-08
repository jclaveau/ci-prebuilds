---
name: musl-condvar-slow-but-not-the-gap
description: musl's condvar round trip is 2.4x glibc's while the socket one is at parity — but WebKit takes 0.29 waits per evaluate, so it is not eval_rtt
metadata:
  type: project
---

Measured on one machine with `playwright/bench/ipc-rtt-bench.c`, both pairs
pinned to CPU 0, n=3:

| primitive | musl | glibc |
|---|---|---|
| socketpair round trip | 14.1 us | 14.4 us |
| pthread condvar round trip | **23.6 us** | **9.7 us** |

The socket one is the kernel's, so it is at parity by construction. The
condvar one is the libc's, and musl's is 2.4x.

**It is still not the `eval_rtt` gap.** `cond-counter.c` (LD_PRELOAD, counters
in an mmap'd file) over a 25 s eval_rtt loop: the busiest process took 9503
waits + 1240 timedwaits across 36 500 evaluates — **0.29 waits per evaluate**.
At 14 us of extra cost each that is ~4 us of a 410 us iteration, about 1%,
against a row that reads 1.10-1.14x.

**Why:** `eval_rtt` and `click_force` profiles are ~50% idle, which makes
"what does a wait cost" the obvious question — and the answer is a real musl
deficiency that happens not to be on this path. glib does not use pthread
condvars at all (futex directly); libWPEWebKit imports all six.

**How to apply:** keep the bench as a control in `wk-lag-diagnostics.yml` —
it is cheap and it separates "the kernel" from "the libc" in one reading. And
count the calls before pricing them: a 2.4x primitive at 0.29 calls per
iteration is worth 1%.
