---
name: project-conformance-runner-node-bound-to-pw
description: conformance runner's node = the exact node mcr.microsoft.com/playwright:v<PW>-noble runs, resolved per run (390fdd8); PW tests depend on node version (chunked responseBodySize 5175 vs 5113)
metadata:
  type: project
---

Since 2026-11-17 (390fdd8) the conformance runner no longer uses apk `nodejs`. `pw-conformance.yml` job `runner-node` runs `node --version` in the official image of `inputs.pw_version`; `build-runner.sh` installs that exact version from unofficial-builds (musl, checksum from same host = integrity only). Standalone callers resolve it inside build-runner.sh.

Trigger: Alpine 3.24 nodejs 24.22.3 coalesces same-tick res.write() into one chunk; PW v1.62.1 `page-network-sizes.spec.ts:78` hardcodes 10-chunk framing → 5113 vs 5175 bytes on chromium. Official v1.62.1 image runs 24.18.1. Upstream fixed the test in v1.65.0 (microsoft/playwright#43409). Verified: chromium 44117387245 + webkit 44117392736 all green.

**Why:** runtime-parity compares our runner vs the official image; a different test-server node makes it measure node, not the browser. Official Dockerfile pins only a major, so the image is the source of truth.

**How to apply:** a conformance red that depends on node behaviour → check `==== Runner node:` line matches the official image before suspecting the browser. Never re-pin node by hand here. Related: [[project_conformance_runner_mirrors_consumer]], [[feedback_never_skip_conformance_tests]].
