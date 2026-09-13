---
name: project_chromium_wrapper_unsets_ld_preload
description: the shipped chrome-headless-shell is a sh wrapper that does `unset LD_PRELOAD` before exec, so an LD_PRELOAD in the container env reaches node and perf but NEVER chromium — a chromium preload probe must rewrite the wrapper and assert a chrome comm loaded the shim before reading anything
metadata:
  type: project
---

`playwright/Dockerfile.alpine` replaces `chrome-headless-shell` with a two-line
wrapper: `unset LD_PRELOAD` then `exec chrome-headless-shell.real`. It exists to
keep the container-wide `LD_PRELOAD=/usr/lib/libmimalloc.so.2` (there for the
Node driver) off PartitionAlloc. Consequence for every probe: **an
`LD_PRELOAD` exported into the consumer container reaches node, perf and the
coreutils, and never the browser.**

**Why:** the first dispatch of the counting-memset arm (run 34584573960, PR
#211) counted 85K calls and named no chromium process; perf still put 100% of
memset in ld-musl and `libmsc.so` was in no table. The histogram read as a
finding about chromium and was a finding about node — a textbook
[[feedback_verify_ab_varied_the_variable]] miss, caught only because the
process table listed `MainThread`/`perf`/`sed` and no `chrome-headless`.

**How to apply:** a preload aimed at chromium in the shipped image goes
THROUGH the wrapper — rewrite `unset LD_PRELOAD` to `export LD_PRELOAD=...`
inside the disposable container and fail if the line is not there (PR #217).
Then assert the variable varied before reading: the shim announces itself at
load (`loaded pid= comm=`) and the arm fails unless a `comm=chrome*` line
exists. The scratch artifact used by the static arms (`image_ours`) has no
wrapper, which is why the fast-string arm's `preload-pids.txt` counted 6 pids
there and the same env did nothing in the consumer image. Related:
[[project_chromium_faststring_moves_layout_text]] (its shipped shim is loaded
by the wrapper's own `CHS_FAST_STRING` switch, not by env),
[[project_chromium_residual_gap_candidates]].
