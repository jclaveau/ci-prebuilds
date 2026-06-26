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

**Why:** the DOM holds the element but PW's visibility check (bounding box > 0 + not display:none + not visibility:hidden) returns false. Hypothesis: layout/viewport not initialized properly on headless-shell + Alpine/musl combo — possibly an interaction with `--no-startup-window` chromium flag (in default PW launch args), missing font apks blocking layout pass, or zero-viewport at newPage. PW SDK launch args printed during smoke include `primaryPointerType=4` (touch) which would also explain click misalignment.

**How to apply:** when investigating any "element is not visible" PW failure on chromium-headless-shell artifact, treat as cluster-related, NOT per-test bug. Skip the cluster only AFTER root cause is known. Investigation env: pull the chs-sha-* image + run a single failing PW test against it with `PW_DEBUG_API=1 DEBUG=pw:protocol,pw:browser` and capture a page.evaluate(()=>document.documentElement.outerHTML) at the failure point.

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
