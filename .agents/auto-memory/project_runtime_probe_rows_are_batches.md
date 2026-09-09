---
name: project_runtime_probe_rows_are_batches
description: runtime-probe.cjs's screenshot metric times a loop of 10 shots, not one — differencing it against a per-shot instrument (screenshot-encode-probe.cjs) invents a phantom residual; check the kernel source's loop count before comparing numbers across two different probe scripts
metadata:
  type: project
---

Self-inflicted unit error while chasing WebKit's `screenshot` row (2026-09-08).
`playwright/bench/runtime-probe.cjs`:

```js
metrics.screenshot = await sample(3, async () => {
  for (let i = 0; i < 10; i++) {
    await page.screenshot({ type: 'png' });
  }
});
```

The probe's row (491.5 vs 463.8 ms) is the cost of **10** shots. A separate
encode-diagnosis instrument (`screenshot-encode-probe.cjs`) reports cost
**per shot** (47.6 vs 43.6 ms). Differencing the two numbers directly
(491.5-463.8 = ~28 ms) invented a "capture/readback" residual that never
existed — encode alone already accounted for more than the entire real gap
(+2.77 ms/shot from the probe row ÷ 10, vs +4.0 ms/shot from the encode
diagnosis). A round of profiling work went into explaining a gap that was a
factor-of-10 arithmetic slip, not a real signal.

Caught by cross-checking a third instrument (`perf record` wall-clock,
+1.45 ms/shot) against the other two and finding the units didn't line up —
not by re-reading the first script sooner.

**How to apply:** before comparing a "row" from one probe script against a
number from a different probe script, read BOTH scripts' loop counts first.
A metrics object's row name (`screenshot`, `click_force`, etc.) does not by
itself say whether it's a per-op or per-batch number — that's decided by
whatever `sample()` wraps, per script. See
[[project_wk_screenshot_is_alpine_os_libpng]] for the campaign this
correction belongs to.
