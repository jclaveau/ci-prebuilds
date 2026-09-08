---
name: wk-string-routines-inert
description: The AVX2 string-routine preload is flat on WebKit too — musl memcpy is not the eval_rtt or click_force gap
metadata:
  type: project
---

`playwright/bench/fast-string-preload.c` (AVX2 memcpy/memmove/memset/strlen/
memcmp, with the corrupted-shim gate that proves the lever is connected) was
built into a consumer arm and prepended to webkit's `pw_run.sh` LD_PRELOAD.
Probed against the shipped build on one runner, n=10: **every row within noise**
— click_force 1.24 vs 1.23, eval_rtt 1.14 vs 1.14, launch 1.36 vs 1.35, layout
0.80 vs 0.81.

**Why:** musl's `memcpy` is the single largest user-space symbol in our
click_force and eval_rtt profiles, but at 0.77% of all samples — visible, not
load-bearing. The same shim measured inert on chromium and firefox, so that is
now all three browsers; stop re-proposing it.

**How to apply:** a symbol being top of the flat profile is not the same as it
being the gap. Read the absolute percentage before building an arm around it.
The arm is cheap to rebuild if a future profile puts musl string routines above
a few percent — one `docker build` over the shipped image, no rebuild.
See [[project_chromium_musl_string_routines]] and
[[project_wk_launch_is_mesa_in_the_closure]] for what did pay.
