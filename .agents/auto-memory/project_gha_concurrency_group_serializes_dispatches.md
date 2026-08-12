---
name: gha-concurrency-group-serializes-dispatches
description: GHA workflow concurrency group keyed on `github.ref` alone serializes ALL dispatches on the same branch; scope the suffix by dispatch flavor when flavors touch independent stages/artifacts
metadata:
  type: project
---

GHA `concurrency.group: <name>-${{ github.ref }}` + `cancel-in-progress: false` blocks every subsequent workflow_dispatch on the same branch until the in-flight run finishes — even if the dispatches operate on independent stages/artifacts. The blocked run stays in `status: pending` with ZERO jobs spawned. It is NOT a queue-capacity issue and NOT a billing-limit issue — `gh api .../runs/<id>/jobs` returns `total_count: 0` and `pending_deployments` is empty.

**Diagnostic signature:**
- `gh run view <id> --json status` → `pending`
- `gh api repos/.../actions/runs/<id>/jobs` → `total_count: 0` (no jobs spawned at all)
- `pending_deployments` empty (rules out env protection)
- An OTHER run on the same `github.ref` is `in_progress`

**Why (this repo):** `playwright-alpine-browsers.yml` had `group: playwright-alpine-browsers-${{ github.ref }}` with `cancel-in-progress: false`. v11 chromium-from-source dispatch waited 3h17min behind in-flight FF+WK parallel dispatch on `feat/webkit-alpine-branch-c`. WK builds take ~6h, so v11 would have waited that whole time.

**How to apply:**
- For workflows with multiple independent dispatch flavors, scope the group suffix by flavor:
  `group: <name>-${{ github.ref }}-${{ inputs.<flavor_input> == 'true' && 'flavor-a' || 'main' }}`
- Verify the flavors touch independent image stages / artifact paths / GHCR tags before splitting — same stage = real artifact race.
- Don't blanket-set `cancel-in-progress: true` to escape this; that defeats the never-abort-in-flight-build invariant for the dominant flavor.

**Corollary — the ref in the group is a free parallelism lever.** Because the group
is `pab-${{ github.ref }}-<flavor>`, the SAME flavor dispatched from a different
branch gets a different group and runs **concurrently**. That is the way to A/B two
build configs of a ~13h producer: land variant A on main, `git worktree add -b
<branch>` for variant B, `gh workflow run … --ref <branch>`. Verified 2026-08-12
running two chromium-from-source builds side by side (dcheck-only vs
is_official_build). Confirm it worked by checking BOTH runs spawned jobs — the
blocked signature is `status: pending` with `jobs: 0`.

**Escape hatch for reusable child workflows:** if the child (`uses: ./.github/workflows/foo.yml`) declares `workflow_dispatch` alongside `workflow_call`, you can `gh workflow run foo.yml --ref <branch> -f ...` directly — the child runs UNDER ITS OWN concurrency (or none), skipping the parent's group. Useful when the parent is stuck on a straggler shard and you want to iterate on the child in parallel. Verified 2026-07-08 for `pw-conformance.yml` while `playwright-alpine-browsers.yml` had a run in-flight.

Cross-ref: [[feedback_gha_actions_budget_diagnostic]] is the SIMILAR-LOOKING failure mode (jobs fail fast ~10s). Concurrency-group hang is distinct: zero jobs spawn at all.
