---
name: pw-conformance-visibility-cluster
description: chromium-headless-shell on Alpine fails 100+ PW conformance page tests with "element is not visible" — single root cause cluster (click/check/drag/fill/screenshot)
metadata:
  type: project
---

PW upstream conformance against our chromium-headless-shell artifact (Alpine apk fast path, run 28231516436) shows ~150+ failures in page suite. They cluster under one symptom — PW's auto-wait reports `element is not visible` AFTER successfully resolving the locator.

Example (`page-check.spec.ts:20`, `should check the box @smoke`):

```
- locator resolved to <input id="checkbox" type="checkbox"/>
- attempting click action
  2 × waiting for element to be visible, enabled and stable
    - element is not visible
  - retrying click action
  ...
  56 × waiting for element to be visible
Test timeout of 30000ms exceeded.
```

**Why (root-caused 2026-06-26):** chromium-headless-shell as packaged by Alpine's community/chromium apk ships with the UA stylesheet defaulting form controls to `appearance: none`. Vanilla `<input type='checkbox'>` renders 0px wide; vanilla `<input type='range'>` renders 0px tall. Injecting `appearance: auto !important` via stylesheet restores the 13×13 native checkbox + makes it clickable. Other parts of the cluster are NOT the same cause:

- **Form-control subcluster** (~50 fails): checkbox/range/color inputs, anywhere PW's locator hits a default-sized form control. ROOT CAUSE: Alpine chromium UA-stylesheet drops `appearance: auto` defaults (likely so it doesn't need GTK/Qt widget toolkit linked into headless-shell). Affected: page-check, page-fill (range/color), elementhandle-misc / locator-misc "check the box", page-click "checkbox input and toggle", elementhandle-bounding-box.
- **Drag subcluster** (~10 fails): PW's `dragTo` / mouse drag synthesis does NOT fire HTML5 dragstart/dragend handlers in chromium-headless-shell. Affected: page-drag.spec.ts. Not fixable without chromium build patch.
- **Wheel subcluster** (~6 fails): `mouse.wheel(...)` does not scroll. Affected: tests/page/wheel.spec.ts. Not fixable without chromium build patch.
- **Residual** (~10 fails): page-click 1x1-div tests, page-mouse dblclick/pointerdown, page-keyboard Escape-dialog. NOT root-caused yet; 1x1 div clicks DO work in local probe so the failures may be Alpine-runner-specific (locale, timing, or PW fixture state).

Probe live at `playwright/alpine-browsers/conformance/debug/probe-visibility-cluster.cjs`; iterate via local `docker run probe-runner:local` or the dispatch workflow `.github/workflows/pw-conformance-debug.yml`.

**How to apply:** treat the form-control subcluster as DIVERGENCE — chromium-headless-shell on Alpine cannot render native form controls without a build patch. Whole-file skip in chromium.files.txt. Drag + wheel similarly. The 1x1 / dblclick / keyboard-dialog residual needs separate probes (likely 2-3 distinct minor bugs); leave un-skipped pending those.

Failing-cluster spec files (count of fails per file across the run):
- page-check.spec.ts (~8)
- page-click.spec.ts (~12)
- page-drag.spec.ts (~9)
- page-fill.spec.ts (~13)
- page-mouse.spec.ts (~3)
- page-screenshot.spec.ts (~20)
- elementhandle-bounding-box.spec.ts (~5)
- elementhandle-misc.spec.ts (~3 — "check the box")
- elementhandle-screenshot.spec.ts (~6)
- elementhandle-scroll-into-view.spec.ts (~2)
- locator-misc-1/2.spec.ts (~6)
- page-add-locator-handler.spec.ts (~6)
- page-aria-snapshot-ai.spec.ts (~8)
- wheel.spec.ts (~6)

Related: [[pw-upstream-juggler-handshake-hang]] (firefox cousin), [[webkit-alpine-branch-c]].
