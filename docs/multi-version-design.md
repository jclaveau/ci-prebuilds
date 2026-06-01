# Multi-version build matrix — design doc

**Status:** draft for review (not yet implemented)
**Target audience:** anyone reviewing the proposed direction before
implementation starts.

## Problem

Today the producer images bake **one** version of each tool — one
`ARG NODE_VERSION`, one `FROM …/ubuntu:24.04`, etc. Renovate's
customManagers move all of them in lockstep, so on every Renovate PR
the entire fleet shifts to the latest of everything. Consumers who
can't upgrade as fast as we do lose their image as soon as the major
bumps. There's no way for a consumer to say "I need ubuntu 22.04
+ pw 1.50" without forking.

We want two changes, with different cadences.

### 1. Default matrix per push: 2 latest majors per axis

Per-axis vary — **one `primary` stack** with latest of everything,
plus **three sibling stacks** where exactly one axis drops to N-1:

| Stack          | OS major   | Node    | pnpm    | Playwright |
|----------------|------------|---------|---------|------------|
| `primary`      | latest     | latest  | latest  | latest     |
| `node-legacy`  | latest     | **N-1** | latest  | latest     |
| `pnpm-legacy`  | latest     | latest  | **N-1** | latest     |
| `os-legacy`    | **N-1**    | latest  | latest  | latest     |

4 stacks per OS family (`ubuntu`, `alpine`) = 8 spawns per push.

We're explicitly **not** building the N-1 combinations
(`(N-1 OS, N-1 Node, N-1 pnpm)` etc.) by default. Per-axis vary
catches single-axis regressions without the full Cartesian blowup.
N-2 versions and triple-axis-old combinations are handled by the
on-demand path (next section).

### 2. On-demand builds via GitHub issue

A consumer who needs `ubuntu 22.04 + node 20 + pnpm 8 + pw 1.50` (or
any other tuple outside the 4 default stacks) opens an issue from a
template. A workflow auto-triggers on the issue, validates the
request, builds the image, pushes it to Docker Hub with the pinned
tag only (no `:latest`), comments on the issue with the resulting
tag, closes the issue. Hard per-requester quota: **≤3 builds per
24h**, enforced by counting `build-request`-labelled issues that user
opened.

## Tag policy

**Pinned tags only.** No channel-style moving tags (`:node22`,
`:pnpm9`, `:ubuntu25.04`, `:alpine3.20` etc.) get published — only
the exact-version tag for each stack. Consumers pin to that exact tag
and update via Renovate; nothing moves under them.

Tag format: `<os><os_ver>-node<x.y>-pnpm<x.y>-pw<x.y><variant_suffix>`
where `<variant_suffix>` mirrors the suffix already on the image name
(`-gyp`, `-sudoer`, `-gyp-sudoer` when both apply).

Examples:
- `jclaveau/ubuntu-dood-playwright:ubuntu26.04-node24.5-pnpm10.2-pw1.55` (primary)
- `jclaveau/ubuntu-dood-playwright:ubuntu26.04-node22.18-pnpm10.2-pw1.55` (node-legacy)
- `jclaveau/ubuntu-dood-playwright-gyp:ubuntu26.04-node24.5-pnpm10.2-pw1.55-gyp`
- `jclaveau/alpine-dood-playwright-gyp:alpine3.21-node22.22-pnpm9.15-pw1.50-gyp` (on-demand example)

`:latest` continues to point at the **primary stack on main only**
(existing behavior from the prior-merged promote-gate fix). No other
moving tag exists.

## Architecture: spawn the workflow per stack

Instead of rewriting the matrix inside `test-and-publish.yml` to fan
out over N stacks, convert it to a **reusable workflow**
(`workflow_call`) and **spawn it once per stack** from a thin
orchestrator. Same builder serves both the default matrix and the
on-demand path. The internal pipeline stays single-stack and just
gains parameters.

### `test-and-publish.yml` → reusable workflow

Add `workflow_call:` to its `on:` block with inputs:

```yaml
on:
  push: { branches: [main] }  # kept as a fallback (see "Self-trigger" below)
  pull_request: {}
  workflow_call:
    inputs:
      os:             { type: string,  required: true }   # ubuntu | alpine
      os_version:     { type: string,  required: true }   # 26.04 | 3.21 | …
      node_version:   { type: string,  required: true }
      pnpm_version:   { type: string,  required: true }
      pw_version:     { type: string,  required: true }
      stack:          { type: string,  required: true }   # primary | node-legacy | pnpm-legacy | os-legacy | on-demand
      publish_latest: { type: boolean, default: false }
```

Internal changes:

- The existing `matrix: os: [ubuntu, alpine]` collapses to
  `os: [${{ inputs.os }}]`. Same code path, one cell per spawn.
- `inputs.node_version` / `pnpm_version` / `pw_version` /
  `os_version` flow through `build-layer` as `--build-arg`s. Requires
  adding a `build_args:` input to the composite (small change).
- `ubuntu-gha-tools/Dockerfile` + `alpine-gha-tools/Dockerfile` switch
  to `ARG OS_VERSION; FROM …/ubuntu:${OS_VERSION}`.
- The `versions` job (post-build `docker run … node -v` extractor)
  goes away. The pinned tag is composed from `inputs.*` plus the
  variant suffix:

  ```bash
  case "${IMAGE_NAME}" in
    *-gyp-sudoer) SUFFIX=-gyp-sudoer ;;
    *-gyp)        SUFFIX=-gyp ;;
    *-sudoer)     SUFFIX=-sudoer ;;
    *)            SUFFIX= ;;
  esac
  TAG="${OS}${OS_VERSION}-node${NODE_MAJ_MIN}-pnpm${PNPM_MAJ_MIN}-pw${PW_MAJ_MIN}${SUFFIX}"
  ```

- `promote` publishes only the pinned tag. `:latest` is emitted iff
  `inputs.publish_latest == true` (so non-primary spawns don't fight
  over it).

### `build-default-matrix.yml` — orchestrator (new)

```yaml
on:
  push: { branches: [main] }
  pull_request: {}

jobs:
  read-versions:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.matrix.outputs.matrix }}
    steps:
      - uses: actions/checkout@v4
      - id: matrix
        run: |
          M=$(jq -c '{include: [
            {os:"ubuntu", os_version:.ubuntu.current,  node:.node.current,  pnpm:.pnpm.current,  pw:.playwright, stack:"primary",     publish_latest:true},
            {os:"ubuntu", os_version:.ubuntu.current,  node:.node.previous, pnpm:.pnpm.current,  pw:.playwright, stack:"node-legacy", publish_latest:false},
            {os:"ubuntu", os_version:.ubuntu.current,  node:.node.current,  pnpm:.pnpm.previous, pw:.playwright, stack:"pnpm-legacy", publish_latest:false},
            {os:"ubuntu", os_version:.ubuntu.previous, node:.node.current,  pnpm:.pnpm.current,  pw:.playwright, stack:"os-legacy",   publish_latest:false}
            # 4 alpine cells mirror the above
          ]}' versions.json)
          echo "matrix=$M" >> "$GITHUB_OUTPUT"

  call-test-and-publish:
    needs: read-versions
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.read-versions.outputs.matrix) }}
    uses: ./.github/workflows/test-and-publish.yml
    secrets: inherit
    with:
      os:             ${{ matrix.os }}
      os_version:     ${{ matrix.os_version }}
      node_version:   ${{ matrix.node }}
      pnpm_version:   ${{ matrix.pnpm }}
      pw_version:     ${{ matrix.pw }}
      stack:          ${{ matrix.stack }}
      publish_latest: ${{ matrix.publish_latest }}
```

Matrix-driven reusable workflow calls have been GA in GHA since 2022.
The 8 spawns run as separate workflow runs — each visible in the
Actions tab, retryable independently without rerunning siblings.

### `on-demand-build.yml` — issue-triggered (new)

Same reusable workflow, single spawn per issue:

```yaml
on:
  issues: { types: [opened, labeled] }

jobs:
  prepare:
    if: contains(github.event.issue.labels.*.name, 'build-request')
    runs-on: ubuntu-latest
    outputs: …  # parsed os/os_version/variant/flavor/versions/pinned_tag, quota_ok, already_exists
    steps:
      - id: parse  # small jq/awk over the issue body; no 3rd-party action
        …
      - id: quota
        run: |
          since=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
          count=$(gh issue list --repo "$GITHUB_REPOSITORY" \
            --author "${{ github.event.issue.user.login }}" \
            --label build-request --state all \
            --search "created:>=$since" --json number | jq 'length')
          [ "$count" -gt 3 ] && { gh issue comment … --body "quota exceeded"; \
            gh issue edit … --add-label quota-exceeded; \
            echo "quota_ok=false" >> "$GITHUB_OUTPUT"; exit 0; }
          echo "quota_ok=true" >> "$GITHUB_OUTPUT"
      - id: existing  # docker manifest inspect; skip build if tag already on Docker Hub
        …

  build:
    needs: prepare
    if: needs.prepare.outputs.quota_ok == 'true' && needs.prepare.outputs.already_exists != 'true'
    uses: ./.github/workflows/test-and-publish.yml
    secrets: inherit
    with:
      os:             ${{ needs.prepare.outputs.os }}
      os_version:     ${{ needs.prepare.outputs.os_version }}
      node_version:   ${{ needs.prepare.outputs.node }}
      pnpm_version:   ${{ needs.prepare.outputs.pnpm }}
      pw_version:     ${{ needs.prepare.outputs.pw }}
      stack:          on-demand
      publish_latest: false

  comment-close:
    needs: [prepare, build]
    if: always() && needs.prepare.outputs.quota_ok == 'true'
    runs-on: ubuntu-latest
    steps:
      - …  # success: comment pinned tag + close; failure: comment logs + label build-failed
```

### Self-trigger compatibility

`test-and-publish.yml` keeps its `push`/`pull_request` triggers as a
fallback (e.g. ad-hoc debugging, `act` runs). When the trigger is not
`workflow_call`, a leading `defaults` job populates the inputs from
`versions.json`'s `current` fields + `stack: 'primary'`. A no-arg
manual run still works.

Alternative considered: drop the triggers from `test-and-publish.yml`
entirely, so only the orchestrator and on-demand workflows ever call
it. Cleaner separation but loses the ad-hoc-trigger affordance. The
plan keeps the fallback for now and removes later if it turns out
unused.

## Issue template

`.github/ISSUE_TEMPLATE/build-request.yml`:

```yaml
name: Build request (specific version combo)
description: Request a build of a specific version tuple outside the default matrix
title: "[build] <os> <os_ver> + <variant> + ..."
labels: ["build-request"]
body:
  - type: markdown
    attributes:
      value: |
        Auto-triggered on submit, hard-capped at 3 builds per requester per 24h.
        Pushed to Docker Hub with the pinned tag only (no `:latest`, no test-gating).
  - type: dropdown
    id: os
    attributes: { label: OS family, options: [ubuntu, alpine] }
    validations: { required: true }
  - type: input
    id: os_version
    attributes: { label: "OS version (e.g. 22.04, 3.18)" }
    validations: { required: true }
  - type: dropdown
    id: variant
    attributes:
      label: Image variant
      options:
        - gha-tools
        - dood
        - dind
        - dood-node
        - dind-node
        - dood-pnpm
        - dind-pnpm
        - dood-pnpm-gyp
        - dind-pnpm-gyp
        - dood-playwright
        - dind-playwright
        - dood-playwright-gyp
        - dind-playwright-gyp
    validations: { required: true }
  - type: dropdown
    id: flavor
    attributes: { label: Flavor, options: [default (hardened), sudoer], default: 0 }
  - type: input
    id: node_version
    attributes: { label: "Node version (if variant ≥ node)" }
  - type: input
    id: pnpm_version
    attributes: { label: "pnpm version (if variant ≥ pnpm)" }
  - type: input
    id: pw_version
    attributes: { label: "Playwright version (if variant = playwright*)" }
```

`labels: [build-request]` auto-applies the label so the workflow's
`if:` filter matches without manual triage.

## versions.json

```json
{
  "ubuntu":     { "current": "26.04",  "previous": "25.04" },
  "alpine":     { "current": "3.21",   "previous": "3.20" },
  "node":       { "current": "24.5.0", "previous": "22.18.0" },
  "pnpm":       { "current": "10.2.0", "previous": "9.15.3" },
  "playwright": "1.55.0"
}
```

Each field is its own Renovate customManager target. `previous`
fields are locked to their major via packageRule `allowedVersions`
(`>=22 <23`, `>=9 <10`, etc.). When a `current` major bumps, the
`previous` value AND its `allowedVersions` range shift up one notch
manually — a one-shot move documented in `renovate.json` as a comment.

OS semantics: "latest 2 tags of each", incl. interim Ubuntu releases
(25.04, 26.04). The choice is to track tag movement rather than LTS
status, so a Renovate PR opens within ~hours of an interim Ubuntu
release.

## Renovate changes

Drop the 4 existing single-ARG customManagers (the Dockerfile `ARG`
lines stop being authoritative — only `versions.json` is). Add new
customManagers — one per `versions.json` channel field — each
regex-matching its own line with named-group `currentValue`
extraction. Per-channel packageRule `allowedVersions` constraints
lock each `previous` field to its major.

Keep `extends`, `pinDigests`, `schedule`, `automerge`,
`prHourlyLimit`, `prConcurrentLimit` unchanged. Keep the existing
`nektos/act` customManager.

## Phasing

Smaller PRs, orchestrator-first:

1. **Phase 1 — make `test-and-publish.yml` reusable (no behavior change).**
   Add `workflow_call:` with inputs (defaulting to current
   single-stack values via a `defaults` job for the existing
   `push`/`pull_request` triggers). Add `build_args:` to `build-layer`.
   Switch the two gha-tools Dockerfiles to `ARG OS_VERSION`. Collapse
   the inner `os` matrix. Everything still builds the same single
   stack. Reviewable in isolation.

2. **Phase 2 — orchestrator + versions.json.** Add `versions.json`
   (current versions only, no `previous` yet). Add
   `build-default-matrix.yml` reading it and calling test-and-publish
   once with `stack: 'primary'`. Move the `push`/`pull_request`
   triggers off `test-and-publish.yml` to the orchestrator. Still one
   spawn per push. Input-gate `:latest` (only on
   `publish_latest: true`). Pinned tag includes the variant suffix.

3. **Phase 3 — populate legacy stacks.** Add `previous` channels to
   `versions.json` (Node 22.18, pnpm 9.15, ubuntu 25.04, alpine 3.20).
   Update orchestrator matrix to spawn all 4 stacks per OS family.
   Update `renovate.json` customManagers + packageRule
   `allowedVersions` for `versions.json`. First push with the full
   8-spawn fleet. Big-impact PR — observe the first run.

4. **Phase 4 — on-demand workflow.** Add
   `.github/ISSUE_TEMPLATE/build-request.yml` and
   `.github/workflows/on-demand-build.yml`. README section
   documenting the workflow + quota. Reuses Phases 1+2 as-is; only
   new code is the issue parser + quota check + close/comment logic.

5. **Phase 5 (deferred) — per-stack test coverage policy + sudoer
   policy.** Decide whether legacy stacks run the full test suite vs
   smoke-only. Decide whether `-sudoer` builds for non-primary
   stacks.

## Out of scope

- Per-stack test coverage policy (Phase 5).
- `-sudoer` flavor coverage for non-primary stacks (Phase 5).
- "On-demand request matches the default matrix → point at the
  existing tag" detection in `on-demand-build` (`manifest inspect`
  precheck already short-circuits exact matches; the missing piece is
  matching a request to a stack rather than to a specific tag).
- Channel-style moving tags (`:node22`, `:pnpm9`, `:ubuntu25.04`,
  `:alpine3.20`) are **out of scope by design**, not deferred — only
  pinned tags get published. Re-adding them later is a one-step
  `metadata-action` addition if the call ever comes.
- Automatic promotion of frequently-requested combos into the default
  matrix.
- Concurrency cap on the orchestrator: 8 parallel spawns × today's
  wall-clock × GHA per-account concurrency limits might queue.
  Observe in Phase 3.

## Risks

- **Reusable workflow secrets:** calls don't inherit secrets unless
  `secrets: inherit` is set. Confirmed used in both orchestrator and
  on-demand. Without it, the `DOCKERHUB_TOKEN` push fails.
- **Actions tab clutter:** 8 parallel runs per push. The "Test and
  Publish" badge in README must repoint to the orchestrator workflow.
- **`:latest` race:** if two pushes land within the same primary-spawn
  wall-clock, both try to push `:latest`. Orchestrator concurrency
  group `build-default-matrix-${{ github.ref }}` with
  `cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}` (same
  pattern as the prior-merged Finding #2) serializes main runs.
- **On-demand wall-clock:** chain build to playwright is 15–30 min;
  the user might give up. Mitigation: comment on the issue when the
  `build` job starts.
- **Docker Hub rate limit:** manifest-inspect precheck has a 100/6h
  anon limit. Auth with `DOCKERHUB_TOKEN` if needed.
- **Issue-form parsing:** depends on the form's body layout. Plan uses
  a small `jq`/`awk` parser rather than a 3rd-party action — avoids
  the supply-chain risk a pinned `digests` policy can't fully cover.

## Open questions for reviewers

1. Is "per-axis vary" (1 + 3 stacks) the right shape, or do we want to
   start narrower (primary-only) and grow into legacy stacks only when
   a consumer asks via the on-demand path? I chose per-axis to catch
   regressions early; the cost is ~4× the build cells.
2. Should `:latest` move with the primary stack, or should we drop
   `:latest` entirely to push consumers toward explicit pinning? The
   plan keeps `:latest` for backwards compatibility but it does create
   a "what does latest actually mean now" question.
3. The on-demand quota is "3 builds / 24h per author, counted from
   `build-request`-labelled issues". Does this feel right, or do we
   want a different surface (e.g. allowlist of GitHub usernames, or
   only authenticated consumers via OIDC)?
4. The Renovate `allowedVersions` ranges are per-major. When a
   `current` major bumps (e.g. Node 24 → 26), `previous` and the
   range need a manual shift. Acceptable as a quarterly chore, or do
   we want a script that does the shift automatically?
