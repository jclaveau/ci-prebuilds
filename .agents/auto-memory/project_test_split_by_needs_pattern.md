---
name: test-split-by-needs-pattern
description: When a test-job matrix mixes flavors with DIFFERENT `needs:` (e.g. build-chain vs build-hardened-variants), split into separate jobs so the lighter side doesn't wait for the heavier. Mirrors test-dind-hardened-effects (existing) and test-gha-tools-effects + test-gha-tools-hardened-effects (commit 5ea013e).
metadata:
  type: project
---

Architectural pattern, applied 5ea013e: `test-gha-tools-effects` previously had matrix `flavor: ['', '-hardened']` and `needs: [build-gha-tools, build-hardened-variants]`. `build-hardened-variants` runs LAST (its own `needs:` enumerates every build-* job), so the entire test job sat behind the slowest layer in the graph — even for the 7-of-8 hardening-INVARIANT steps (WORKDIR, USER, env, dir perms).

Fix: split into two jobs:
- `test-gha-tools-effects` — build-chain only, `needs: build-gha-tools`. Runs early.
- `test-gha-tools-hardened-effects` — sudo-denial assertion only, `needs: build-hardened-variants`. Tiny job; sits behind hardened, harmless.

**When this pattern applies**: any test-job whose `matrix.flavor` (or similar dimension) mixes build artifacts that come from different `build-*` jobs. GHA can't have per-matrix-entry `needs:` — split is the only correct shape.

**Reference template**: pre-existing `test-dind-hardened-effects` (test-and-publish.yml:867) does exactly this for the dind family's narrow-sudoers contract.

**Safety check before splitting**: confirm the "shared" assertions really are invariant across flavors. If `harden/Dockerfile` only strips sudoers (which it does — `rm -f /etc/sudoers.d/runner`), then WORKDIR/USER/env/perms ARE invariant and re-testing them on hardened was paranoia.
