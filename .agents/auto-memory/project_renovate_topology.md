---
name: renovate-topology
description: What renovate.json tracks in ci-prebuilds — customManagers per ARG pin, lockstep groupNames, GHCR consumer fallback via extractVersionTemplate, automerge:true GLOBALLY
metadata:
  type: project
---

**Custom managers** (regex over `ARG <NAME>=` and `<NAME>: ` patterns):
- `DOCKER_VERSION` → docker/docker, `NODE_VERSION` → node-version/node
- `PLAYWRIGHT_VERSION` (Dockerfile + Dockerfile.alpine) + `PW_VERSION` (versions.env) → npm/playwright — all share the `Playwright` groupName for lockstep with `@playwright/test`
- `PNPM_VERSION` across pnpm/, pnpm-gyp/{Dockerfile,Dockerfile.alpine} → npm/pnpm
- `ACT_VERSION:` in any workflow → github-releases/nektos/act
- `OS_VERSION` per OS (alpine-gha-tools→alpine, ubuntu-gha-tools→ubuntu)
- `UBUNTU_VERSION` in Dockerfile.glibc-debug
- `CHS_REV` in playwright/Dockerfile.alpine → datasource: docker, depName: `ghcr.io/jclaveau/playwright-alpine-browsers`, **`extractVersionTemplate: ^chs-(?<version>\d+)$`**, versioning: loose. This is the alpine consumer's fallback path tracked by the GHCR tag scheme `chs-NNN` from the producer side — see [[pw-version-aware-chs-rev-chain]].

**Global**: `automerge: true`, `automergeStrategy: squash`, `platformAutomerge: false`, `rebaseWhen: conflicted`, `osvVulnerabilityAlerts: true`, `schedule: before 6am every weekday` (Europe/Paris), `prHourlyLimit: 0`, `prConcurrentLimit: 5`.

**Why automerge:true is GLOBAL (not scoped):** Iterated through 3 versions (scoped→stack-internal-only→global) before user concluded "automerge in any case" — including stack-internal transitives (e.g. PW's own deps that Renovate proposes in playwright/package.json). The producer/consumer image pipelines and `tests-aports.yml` are the safety net; CI failure blocks merge, so automerge is bounded by green CI regardless of category. Do NOT re-scope without explicit ask.

**How to apply:**
- Adding a new ARG-based version pin → add a customManager block following the existing pattern; if the file location is unusual, anchor the fileMatch regex.
- Renaming the producer image away from `ghcr.io/jclaveau/playwright-alpine-browsers` → update the CHS_REV customManager's depNameTemplate AND the consumer FROM stage alias (see [[buildkit-arg-in-copy-from]]).
- Adding a per-rule `automerge: false` override smells wrong here — push back; the user's stated default is global automerge.
- Majors included (ruled again 2026-09-21): a `matchUpdateTypes: ["major"] → automerge: false` rule lived one day (PR #286 → dropped). The `:latest` runtime-change worry is covered by version-pinned tags plus the build-request issue form (`on-demand-build.yml` rebuilds any older node/pnpm/pw combo as a pinned tag), and majors had automerged before without incident (#235 pnpm v12). TP build-tests + conformance gate every automerge regardless of category, so a green-CI major is already vetted. Don't propose a majors (or node/ubuntu-specific) exception again without a new rationale.
- **`platformAutomerge: false` is what makes "bounded by green CI" true** (2026-11-07): main has no branch protection, so GitHub native auto-merge had no required check to wait for. Renovate merged node 26 bump #349 at 10:06:27, 1.5 min into its Test and Publish run, which then failed (build-node-dood alpine: no node-musl image pinned for 26.13.0) and left main red. With it false, Renovate merges itself, only once every check on the branch is green. Do not drop it unless main gains required checks.
- **`rebaseWhen: conflicted`** (2026-11-07): with automerge on, the default rebased all 5 open Renovate PRs on every push to main, ~9 PR runs per push queued ahead of main and dispatched probes, and restarted CI on PRs that had just gone green (docker #356 green at 23:46Z, rebased at 00:28Z instead of merged). Now a green PR merges on Renovate's next run even with main moved; main's own Test and Publish run tests the merged result. Superseded PR runs cancel: Test and Publish, libm-fmod gate, tests-aports, and playwright-alpine-browsers on `renovate/*` heads.
