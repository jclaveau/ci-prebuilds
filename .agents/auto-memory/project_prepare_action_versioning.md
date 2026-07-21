---
name: project_prepare_action_versioning
description: prepare composite action versioned via v0 moving tag + v0.1.0 immutable; first git tags in repo; force-move v0 on compatible action change
metadata:
  type: project
---

The `prepare` composite action (`.github/actions/prepare/action.yml`) is consumed externally as `jclaveau/ci-prebuilds/.github/actions/prepare@v0`. Versioning:

- `v0` — moving tag, advanced manually on **compatible** action updates
- `v0.1.0` — immutable; pin this (or a SHA) for full reproducibility
- `v1` — reserved until the **repo** reaches v1

First git tags created at `a8b5276` (the #59 commit that introduced the action). Note: `ff-*` / `chs-*` are container-image tags, NOT git tags — these `v*` are the repo's first git tags.

**Going forward (convention, no automation):** on a meaningful action change,
`git tag v0.x.y <sha>` then force-move `git tag -f v0 <sha> && git push -f origin v0 v0.x.y`. Breaking change to the action's env contract before repo-v1 → bump minor, note it in the tag message.

**Why:** standard GHA major-tag convention scaled to pre-v1 honesty. Chosen over jumping to v1 (would lock compat promises) and over a release workflow (one action, low churn → manual tagging is enough).

**How to apply:** when editing the prepare action, decide compat → tag + force-move v0. Internal workflow/test refs stay `./.github/actions/prepare` (local path, unversioned by design). See [[project_pre_v1_doc_style]].
