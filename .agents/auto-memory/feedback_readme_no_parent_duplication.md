---
name: readme-no-parent-duplication
description: in image READMEs, never repeat content from parent-image READMEs; link to the parent section instead
metadata:
  type: feedback
---

When documenting a layered image (e.g. `playwright`, `pnpm-gyp`, `dood`, `dind`), do NOT
restate facts/limits/recipes that already live in a parent's README. Link to the parent
section by anchor instead.

**Why:** the image chain is `gha-tools → docker → dood|dind → node → pnpm → pnpm-gyp |
playwright[-gyp]`. Every leaf could otherwise restate parent guarantees → drift, hand-edit
churn when the parent changes, and reader fatigue. The user wants leaves to add only what
THEY contribute and rely on the parent README for inherited behavior.

**How to apply:**
- Adding a new fact: locate the layer where it first becomes true; document there.
- All derived layers (downstream in the BASE_IMAGE chain) cross-ref via a one-liner with
  a deep anchor link: `[short name](../<parent>/README.md#<anchor-slug>)`.
- If the derived layer makes the behavior **more acute** (e.g. playwright + pnpm chmod
  limit because pre-baked bins are exactly what get re-`chmod`-ed), add a brief why-it's-worse
  qualifier on the link line, but still no duplicated workaround prose.
- Exception: the top-level `README.md` summary table CAN restate one-liners since it's the
  consumer's entry point — but those should still link out for detail.

Recent application: pnpm chmod-EPERM limit lives in `pnpm/README.md`; `pnpm-gyp`,
`playwright`, and `dood`'s act-bind section link to it via the
`#known-limit-pnpm-install--g-under-act---bind---user-non-1001` anchor — no copy-paste.

Related: [[feedback_wired_up_over_inert]] (don't create inert duplicate content),
[[feedback_no_one_shot_helpers]] (same DRY instinct at code level).
