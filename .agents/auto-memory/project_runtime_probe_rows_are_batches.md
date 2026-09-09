---
name: project_runtime_probe_rows_are_batches
description: runtime-probe.cjs rows are BATCHES (screenshot = 10 shots), while screenshot-encode-probe.cjs reports per shot — differencing the two invented a 24 ms phantom
metadata:
  type: project
---

`playwright/bench/runtime-probe.cjs` times a loop per row, not one operation:

```js
metrics.screenshot = await sample(3, async () => {
  for (let i = 0; i < 10; i++) {
    await page.screenshot({ type: 'png' });
  }
});
```

`click_force` likewise clicks every node.
`playwright/bench/screenshot-encode-probe.cjs` reports **per shot**.

Comparing them directly turned a real +2.77 ms/shot gap into a claimed +27.7 ms
(491.5 vs 463.8 for ten shots, against 47.6 vs 43.6 for one), so a 4.0 ms/shot
encode delta looked like 15% of the cost with ~24 ms of "capture/readback" left
to find. There was no residual: encode was >= the whole gap, and a perf record
later confirmed no capture DSO carries measurable time.

What caught it was a THIRD instrument disagreeing — `perf record` wall-clock at
+1.45 ms/shot would not line up with either — not re-reading the first script.

**How to apply:** before differencing two harnesses, read both kernel bodies and
confirm they report the same unit. A row name (`screenshot`, `click_force`) does
not say whether it is per-op or per-batch; whatever `sample()` wraps decides,
per script. When a residual appears that no profile can locate, suspect the
arithmetic before inventing a mechanism —
[[feedback_verify_before_asserting]] [[project_wk_screenshot_is_alpine_os_libpng]]
