---
name: project_gha_dispatch_and_stacked_pr_gotchas_2026_10_09
description: three CI-mechanics gotchas from the fmod campaign — workflow_dispatch 404s for a workflow file only on a branch, perf-gate candidate_build_args as an ad-hoc A/B (ratio direction), squash-merging a base PR conflicts the stacked PRs (rebase --onto); plus tests-aports red since 10-08 = unauthenticated api.github.com 403
metadata:
  author: Jean Claveau
  type: project
---

**1. `gh workflow run` on a workflow file that exists only on a branch → HTTP 404.** Manual dispatch needs the file on the default branch. To run a new gate on its branch: open a draft PR (its `pull_request` trigger runs it; unlabeled draft PRs are cheap here), or temporarily add a push trigger. Done for libm-fmod-custom-gate (#332, run 37927015098).

**2. Ad-hoc A/B of an env/preload knob: use `perf-gate` with `candidate_build_args`**, not chs-perf-ab (no preload input). Both arms build through the real `Dockerfile.alpine`. Put the knob OFF in candidate, ON in promoted (the default) when the branch default is ON: the ratchet ratio then reads without/with, so >1.00 means the knob helps. Runs 37933876301 + 37936829426: fmodf preload flat (geo 0.990, 1.001). GitHub picks the runner CPU — two dispatches both landed on AMD, an Intel draw cannot be forced.

**3. Squash-merging a base PR leaves stacked PRs conflicting** (their branch still carries the old commits of the base). Retarget onto main, then `git rebase --onto origin/main <last-base-commit>` replays only their own commits; force-push re-runs CI, so it needs a go. #333 merged clean, #334 conflicted in 4 files after #332's squash (3f06490).

**4. tests-aports red on main since 2026-10-08 evening** (last green 1df1d2e): step "aports fetch failover (both hosts)" blocks gitlab and expects github; `api.github.com` answers `curl: (22) 403` on the runner, 200 from jean's box. `aports-fetch.sh:32` sends no token → guess: shared-runner IP rate limit. Proposed fix (not applied, awaits go): send `Authorization: Bearer $GITHUB_TOKEN` when set, pass `GITHUB_TOKEN` in `tests-aports.yml`. Unverified guess until the fix run.

**Why:** each cost a wrong first approach or a surprise 404.
**How to apply:** see [[project_tp_paths_ignore_ships_nothing]], [[project_fmod_everywhere_preload_vs_patched_musl]].
