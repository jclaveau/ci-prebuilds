---
name: project_runtime_probe_rows_are_batches
description: runtime-probe.cjs rows are BATCHES (screenshot = 10 shots), while screenshot-encode-probe.cjs reports per shot — differencing the two invented a 24 ms phantom
metadata:
  type: project
---

`playwright/bench/runtime-probe.cjs` times a loop per row, not one operation:
`metrics.screenshot` wraps **10** `page.screenshot({type:'png'})`, `click_force`
clicks every node. `playwright/bench/screenshot-encode-probe.cjs` reports **per
shot**.

Comparing them directly turned a real +2.77 ms/shot gap into a claimed +27.7 ms,
so a 4.0 ms/shot encode delta looked like 15% of the cost with ~24 ms of
"capture/readback" left to find. There was no residual: encode was >= the whole
gap, and a perf record later confirmed no capture DSO carries measurable time.

**How to apply:** before differencing two harnesses, read the kernel body and
confirm both report the same unit. When a residual appears that no profile can
locate, suspect the arithmetic before inventing a mechanism —
[[feedback_verify_before_asserting]].
