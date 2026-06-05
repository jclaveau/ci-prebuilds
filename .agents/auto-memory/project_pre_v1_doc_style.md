---
name: pre-v1-doc-style
description: ci-prebuilds is pre-v1 — drop stale historical PR/issue refs (`(actions/runner#266)`, etc) from user-facing docs unless the link is still load-bearing.
metadata:
  type: project
---

For README + per-layer READMEs: don't anchor doc examples to historical PR / issue numbers when the referenced fix is GA and stable. Example: `container.image: ""` doesn't need `(actions/runner#266)` — that PR shipped in runner v2.164.1 years ago.

**Why:** ci-prebuilds hasn't cut a v1 tag yet; every doc revision is allowed to delete stale historical anchors. User said "remove it, the project is still not considered v1" when I dropped `(actions/runner#266)` from the Full-control-usage matrix example's `image: ""` comment.

**How to apply:** Keep refs that are still load-bearing — open upstream bugs (e.g. `pnpm/pnpm#3699` in [[project_pnpm_chmod_eperm_upstream]]), version pins, in-flight PR discussions, or anything a maintainer would still click. Drop refs that document "why this feature didn't work in 2019". When in doubt: would a reader six months from now learn anything from clicking? If not, cut.

Distinct from [[feedback_high_signal_references]] (cross-project) which is about WHICH refs to cite when you cite; this one is about WHEN to drop refs entirely.
