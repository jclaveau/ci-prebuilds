# On-demand version builds via issue template — design doc

**Status:** draft for review (not yet implemented)
**Target audience:** anyone reviewing the proposed direction before
implementation starts.

## Problem

Every Renovate PR moves the whole fleet to the latest of everything —
there's no way for a consumer to ask the fleet for `ubuntu 22.04 +
pw 1.50` (or any other older combination) without forking. I want
to make those combinations buildable on demand, without ballooning
the always-built matrix.

## Proposed shape

**Default per-push behavior stays exactly as today.** Single primary
stack, same images, same `:latest`, same Renovate cadence.

**Anything else is a GitHub issue.** Template captures a specific
version tuple, a workflow auto-builds it on issue open (hard quota of
3 builds/24h per requester), pushes to Docker Hub with the pinned
tag, comments the tag, closes.

To make this work, `test-and-publish.yml` becomes callable as a
**reusable workflow** (`workflow_call`) so the on-demand workflow can
spawn it with specific version inputs. Its existing `push` /
`pull_request` triggers stay, and the inputs default to empty so the
existing path's behavior is unchanged.

### Earlier iterations of this design (now dropped)

- A **per-axis-vary** default matrix building the 2 latest majors of
  Node/pnpm/OS as 4 stacks per OS family — dropped because the cost
  is high (8 spawns per push) and on-demand covers the same need
  reactively.
- A **`versions.json` source-of-truth file** + Renovate
  customManagers per channel — dropped along with the multi-stack
  matrix.
- A thin **orchestrator workflow** that read `versions.json` and
  fanned out spawns — no longer needed without the multi-stack
  matrix.

## Architecture

### `test-and-publish.yml` → reusable workflow

Add a `workflow_call:` block alongside the existing triggers. **Every
input defaults to empty / `true`**, so the existing `push` /
`pull_request` triggers behave exactly as they do today (the
Dockerfile's `ARG <X>=<default>` values win):

```yaml
on:
  push: { branches: [main] }    # unchanged
  pull_request: {}              # unchanged
  workflow_call:
    inputs:
      os_version:     { type: string,  default: '' }
      node_version:   { type: string,  default: '' }
      pnpm_version:   { type: string,  default: '' }
      pw_version:     { type: string,  default: '' }
      stack:          { type: string,  default: 'default' }   # 'default' | 'on-demand'
      publish_latest: { type: boolean, default: true }
```

Internal changes (small, mostly mechanical):

- `build-layer` composite gains a `build_args:` input. The
  test-and-publish jobs forward each non-empty `inputs.*` as
  `--build-arg KEY=VAL`. Empty → the Dockerfile `ARG` default wins.
- `ubuntu-gha-tools/Dockerfile` + `alpine-gha-tools/Dockerfile`
  switch to `ARG OS_VERSION=<current>` + `FROM …:${OS_VERSION}`.
  Default preserved → no per-push behavior change.
- The pinned tag composition stays where it is (the `versions` job
  in test-and-publish, which `docker run`s the built image to read
  versions) — works for both the default and on-demand paths, since
  the built image's actual versions are what get tagged either way.
- Pinned tag format gains the **variant suffix** (`-gyp`, `-sudoer`,
  `-gyp-sudoer`) extracted from the image variant name. Applies to
  both default and on-demand paths for consistency. Example:
  `jclaveau/alpine-dood-playwright-gyp:alpine3.21-node22.22-pnpm9.15-pw1.50-gyp`.
  Light retrocompat impact on anyone pinned to the old gyp/sudoer
  tag without the suffix (both flavors are recent).
- `promote` emits `:latest` iff `inputs.publish_latest == true`. On
  the push/PR path that's the default → unchanged. On-demand passes
  `false` → only the pinned tag is published, never `:latest`.

### `on-demand-build.yml` (new)

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
      os_version:     ${{ needs.prepare.outputs.os_version }}
      node_version:   ${{ needs.prepare.outputs.node_version }}
      pnpm_version:   ${{ needs.prepare.outputs.pnpm_version }}
      pw_version:     ${{ needs.prepare.outputs.pw_version }}
      stack:          on-demand
      publish_latest: false

  comment-close:
    needs: [prepare, build]
    if: always() && needs.prepare.outputs.quota_ok == 'true'
    runs-on: ubuntu-latest
    steps:
      - …  # success: comment pinned tag + close; failure: comment logs + label build-failed
```

### Issue template

`.github/ISSUE_TEMPLATE/build-request.yml`:

```yaml
name: Build request (specific version combo)
description: Request a build of a specific version tuple
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
`if:` filter fires.

## Tag policy

**Pinned tags only.** No channel-style moving tags (`:node22`,
`:pnpm9`, `:ubuntu25.04`, `:alpine3.20`). Consumers pin to the exact
tag they want; nothing moves under them.

`:latest` continues to point at the primary stack on main, same as
today (default-path push with `publish_latest: true`).

## Phasing

1. **Phase 1 — `test-and-publish.yml` reusable + Dockerfile ARGs.**
   Add `workflow_call:` with inputs (defaults preserve today's
   behavior). Add `build_args:` to `build-layer`. Switch the two
   gha-tools Dockerfiles to `ARG OS_VERSION`. Add variant suffix to
   the pinned tag. Direct push/PR runs produce the same images as
   today (verified via manifest digest match for non-gyp variants).

2. **Phase 2 — issue template + on-demand workflow.** Add
   `.github/ISSUE_TEMPLATE/build-request.yml` and
   `.github/workflows/on-demand-build.yml`. README section
   documenting the on-demand flow + quota.

## Out of scope

- The per-axis-vary multi-stack default matrix (earlier iteration,
  dropped).
- A `versions.json` central registry (dropped).
- An orchestrator workflow (dropped).
- Channel-style moving tags (`:node22`, `:pnpm9`, etc.) — design
  decision, not a deferral.
- Automatic promotion of frequently-requested on-demand combos into
  the default per-push build.

## Risks

- **Reusable workflow secrets:** calls don't inherit secrets unless
  `secrets: inherit` is set. Without it the `DOCKERHUB_TOKEN` push
  fails.
- **Variant-suffix retrocompat:** consumers pinned to
  `…-pw1.50` for a `-gyp` / `-sudoer` variant need to repoint to the
  new `…-pw1.50-gyp` (resp. `-sudoer`). Both flavors are recent so
  blast radius is small; call out in release notes.
- **On-demand wall-clock:** chain-build to playwright takes 15-30
  min; the user might give up. Mitigation: comment on the issue when
  the `build` job starts.
- **Docker Hub manifest-inspect rate limit:** 100/6h anon on the
  `already_exists` precheck. Auth with `DOCKERHUB_TOKEN` if needed.
- **Issue-form parsing:** depends on the form's body layout. Plan
  uses a small `jq`/`awk` parser rather than a 3rd-party action.

## Open questions for reviewers

1. Pinned-tag variant suffix — keep (consistent across default +
   on-demand) or skip on the default path to avoid the retrocompat
   nibble? Current plan: keep.
2. On-demand quota — 3 builds/24h per author, counted from
   `build-request`-labelled issues opened by that author. Sensible,
   or do we want a different gate (allowlist, OIDC, larger quota)?
3. If `test-and-publish.yml` keeps its `push` / `pull_request`
   triggers AND becomes a reusable workflow, does anyone want to
   drop the direct triggers once the on-demand path lands? Current
   plan: keep, both paths coexist; drop later if unused.
