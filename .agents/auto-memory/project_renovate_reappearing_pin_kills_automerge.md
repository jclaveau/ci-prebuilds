---
name: project_renovate_reappearing_pin_kills_automerge
description: renovate silently disables automerge forever on a dep once it sees the old version "reappear" after a prior automerge, even in a commented-out line; a partial fix (only the live line) does NOT lift the block — every reappeared instance, commented included, must land in ONE PR
metadata:
  type: project
---

`#236`/`#237` (build-push-action v7, login-action v4) sat with checks green
and automerge enabled but never merged. Cause: their PR bodies say "Automerge:
Disabled because a matching PR was automerged previously." Renovate had
already automerged v7/v4 once (#107/#148, August); afterward
`chromium-clang-toolchain.yml:81/99` came back with `login-action@v3` +
`build-push-action@v6` (a hand-edit or revert), and `test-and-publish.yml:1772`
still has a **commented-out** `# uses: docker/login-action@v3` line. Renovate's
github-actions manager matches commented `uses:` lines too, reads the old
version's reappearance as evidence the automerge was reverted, and refuses to
automerge that dep again — permanently, not just for one PR.

Fix is a manual one-line-per-file bump of the reappeared pins (not a renovate
config change — [[project_renovate_topology]]'s automerge:true is already
global and correct); once the stale pins are gone, close #236/#237 and the
next bump automerges normally.

**How to apply:** if a renovate PR shows green checks + automerge enabled but
sits unmerged for days, check the PR body for this exact sentence before
assuming a schedule/limit problem. Grep the repo for the OLD pinned version,
including inside comments — a leftover comment is enough to trip this.

**2026-09-23 — a third instance (`#295`, `actions/checkout`) confirmed a
PARTIAL fix does not lift the block.** `#295` alone touched only the live
reappeared pin (`image-pull-bench.yml:27`); a second commented instance
(`test-and-publish.yml:1783`) kept tripping renovate regardless, so
merging #295 alone would not have restored automerge. Fix: fold every
reappeared instance across every file — including #236/#237's two
`docker/*-action` pins in `chromium-clang-toolchain.yml` and their own
commented twin at `test-and-publish.yml:1784` — into **one** PR (`#308`,
5 lines across 3 files), merge it, then close #295/#236/#237 as
redundant subsets. Next bump of any of the three dependencies then
automerges normally. Lesson: when this pattern recurs, `grep` for the
old version repo-wide FIRST and fix every hit in a single PR — do not
merge a same-day narrower PR (like #295) that touches only one of the
reappeared lines, since it cannot lift the block by itself and leaves a
second redundant PR to clean up after.
