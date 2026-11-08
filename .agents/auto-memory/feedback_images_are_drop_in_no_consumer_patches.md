---
name: images-are-drop-in-no-consumer-patches
description: ci-prebuilds images are drop-in replacements; never propose patching the consumer workflow (e.g. dropping pnpm/action-setup) as a fix — fix in the image, or upstream
metadata:
  type: feedback
---

A ci-prebuilds image must be a drop-in for the `container:` it replaces, needing as few consumer
workflow edits as possible (ideally only the image tag). Never propose removing or rewriting a
consumer step (`pnpm/action-setup`, `actions/setup-node`, …) to win time. jean said this "many
times"; repeated on 2026-11-08 over Planner #830.

**Why:** the value of the images is swapping one line; every extra patch is a per-consumer cost.

**How to apply:** when a consumer step is slower in our image, find why the step can't see what the
image already provides, and fix it on the image side (env, paths, tool cache, as
`register-node-in-tool-cache` does for setup-node) or upstream. A cost equal on the ubuntu image at
the same versions is not ours. See [[images-index]].
