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

**Global**: `automerge: true`, `automergeStrategy: squash`, `osvVulnerabilityAlerts: true`, `schedule: before 6am Mon`, `prHourlyLimit: 2`, `prConcurrentLimit: 5`.

**Why automerge:true is GLOBAL (not scoped):** Iterated through 3 versions (scoped→stack-internal-only→global) before user concluded "automerge in any case" — including stack-internal transitives (e.g. PW's own deps that Renovate proposes in playwright/package.json). The producer/consumer image pipelines and `tests-aports.yml` are the safety net; CI failure blocks merge, so automerge is bounded by green CI regardless of category. Do NOT re-scope without explicit ask.

**How to apply:**
- Adding a new ARG-based version pin → add a customManager block following the existing pattern; if the file location is unusual, anchor the fileMatch regex.
- Renaming the producer image away from `ghcr.io/jclaveau/playwright-alpine-browsers` → update the CHS_REV customManager's depNameTemplate AND the consumer FROM stage alias (see [[buildkit-arg-in-copy-from]]).
- Adding a per-rule `automerge: false` override smells wrong here — push back; the user's stated default is global automerge.
