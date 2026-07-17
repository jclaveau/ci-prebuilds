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

**Why (root-caused 2026-06-26, second probe):** Alpine's community/chromium apk ships chromium-headless-shell with a **broken or truncated UA stylesheet** — `headless_lib_data.pak` is only 745KB (upstream chromium's chrome_100_percent.pak is multi-MB). Vanilla block elements (`<div>`, `<p>`, `<h1>`, `<article>`, etc.) compute `display: inline` instead of `block`. Form controls compute `appearance: none` instead of `appearance: auto`. The artifact has NO `resources/` directory (where chrome normally stores per-language pak files including the UA stylesheet). This is the SAME root cause for every visibility/sizing failure in the cluster — the UA stylesheet that gives HTML elements their default sizes simply isn't being applied.

Confirmed via four probe runs in `debug/probe-visibility-cluster.cjs` + ad-hoc probes:

  - `<div>` (no styles) — computed `display: inline`
  - `<div style="width:1px;height:1px">` (no content) — boundingBox 0×0 (because inline + no inline content + width/height ignored on inline)
  - `<div style="display:block;width:1px;height:1px">` (override) — boundingBox 1×1 ✓
  - `<input type='checkbox'>` — appearance:none, width:0
  - `<input type='checkbox' style="appearance:auto !important">` — 13×13 ✓

Original four subcluster names still hold but the per-cluster causes collapse into one root cause:

- **Form-control subcluster** (~50 fails): checkbox/range/color inputs. UA stylesheet doesn't apply `appearance: auto` → controls render 0px. Affected: page-check, page-fill (range/color), elementhandle-misc / locator-misc "check the box", page-click "checkbox input and toggle".
- **Drag subcluster** (~10 fails): PW's `dragTo` / mouse drag synthesis does NOT fire HTML5 dragstart/dragend handlers in chromium-headless-shell. Affected: page-drag.spec.ts. Not fixable without chromium build patch.
- **Wheel subcluster** (~6 fails): `mouse.wheel(...)` does not scroll. Affected: tests/page/wheel.spec.ts. Not fixable without chromium build patch.
- **Block-element subcluster** (~15+ fails, formerly "residual"): page-click 1x1-div (8), elementhandle-bounding-box (5), elementhandle-scroll-into-view (2). Vanilla `<div>` computes `display: inline` → boundingBox 0×0 → PW auto-wait `is visible` fails. Same UA-stylesheet root cause as form controls.

- **Residual** (~10-20 fails, still unrelated): page-mouse dblclick/pointerdown, page-keyboard Escape-dialog contenteditable, page-fill contenteditable + body fill, page-goto SSL/networkidle/service-worker, page-autowaiting-no-hang, page-add-locator-handler. Not UA-stylesheet related; each needs its own probe.

Probe live at `playwright/alpine-browsers/conformance/debug/probe-visibility-cluster.cjs`; iterate via local `docker run probe-runner:local` or the dispatch workflow `.github/workflows/pw-conformance-debug.yml`.

**How to apply:** Alpine's community/chromium apk for chromium-headless-shell ships a broken UA stylesheet pak. ALL form-control / block-element / sizing failures collapse into this one bug. Three fix paths:

1. **File Alpine apk bug** (preferred long-term) — `community/chromium` package + `chromium-headless-shell` subpackage. Likely fixed by including the missing `resources/` dir or expanding `headless_lib_data.pak`.

2. **Build from source** (heaviest) — the prebuilt-base / from-source pipeline already scaffolded in playwright-alpine-browsers.yml. Currently `if: false`; would take ~12h cold build.

3. **PW SDK init-script polyfill** (workaround) — inject a `<style>` element with HTML5 UA defaults on every page via PW's addInitScript. This would re-enable PW conformance tests but isn't a true drop-in replacement (users hitting the binary outside PW would still see the bug).

Drag + wheel subclusters are SEPARATE root causes (event source missing), NOT UA-stylesheet related. They stay file-skipped as DIVERGENCE.

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

**CONFIRMED APK-ONLY (2026-07-16):** on **CHS-from-source** (chromium 148, ships the full `chrome_100_percent.pak` UA stylesheet) the visibility cluster passes — page-check + elementhandle-bounding-box + scroll-into-view + add-locator-handler un-skipped clean (+~21). The bug is the ALPINE APK's truncated pak, not chromium/musl. CHS-apk is now paused (workflow_dispatch-only); only CHS-fs consumes the chromium skip-list. Also recovered on CHS-fs the SAME cycle: CHIPS/Partitioned third-party cookies (+11 — defensive apk-era over-skip; chromium 148 ships CHIPS on) and `page-aria-snapshot` (+39 — aria snapshots compare accessible-name TEXT/YAML, NOT pixels, so they don't share the font-rasterization root cause of the pixel-screenshot files; bisected OUT of the screenshot whole-file skip). CHS-fs 84.4%→86.4%.

**Still structural on CHS-fs (headless_shell GN target strips them; from-source 148 identical):** drag/wheel/drop (input paths), pixel-screenshot (Alpine freetype rasterization ≠ reference PNGs). page-aria-snapshot-**ai** stays skipped (LLM-nondeterministic).

Related: [[pw-upstream-juggler-handshake-hang]] (firefox cousin), [[webkit-alpine-branch-c]], [[recorder-family-chromium-bundle]], [[pw-conformance-scope-out-of-scope]].
