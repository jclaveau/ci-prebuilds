---
name: pw-version-aware-chs-rev-chain
description: End-to-end PW → chromium-headless-shell revision propagation across producer, on-demand-build, test-and-publish, and Dockerfile.alpine (PRs 41/42/43)
metadata:
  type: project
---

**Chain:** PW SDK auto-discovers chromium at `/ms-playwright/chromium_headless_shell-<rev>/...`. Mismatch between image's baked `CHS_REV` and SDK's expected rev → `Executable doesn't exist` at runtime. So `CHS_REV` must travel with `PW_VERSION` through every workflow that varies either.

**Flow** (forward path):
1. `on-demand-build.yml` `prepare` job: `curl playwright-core@${PW}/browsers.json | jq '.browsers[]|select(.name=="chromium-headless-shell").revision'` → `chs_rev` output.
2. **Pre-flight** in same step: `docker manifest inspect ghcr.io/jclaveau/playwright-alpine-browsers:chs-${CHS_REV}` — fail loud with guidance if missing.
3. Forwarded as `chs_rev` workflow_call input to `test-and-publish.yml`.
4. `test-and-publish.yml`'s 4 `build-playwright-{dood,dind}{,-gyp}` jobs pass `--build-arg CHS_REV=…` to consumer image build.
5. `playwright/Dockerfile.alpine` uses `ARG CHS_REV` in named stage alias `FROM ghcr.io/.../playwright-alpine-browsers:chs-${CHS_REV} AS chs-source` (BuildKit ARG-in-COPY-from limitation — see [[feedback_buildkit_arg_in_copy_from]]).

**Producer side** (`playwright-alpine-browsers.yml`):
- `pw_version` workflow_dispatch input + `PW_VERSION_OVERRIDE` env override the versions.env default in 3 `pins` steps.
- Weekly `schedule: 0 6 * * 0` accumulates catalog entries.
- chs promote job's `if:` includes `workflow_dispatch` so on-demand catalog dispatches publish.
- chs build step passes `EXPECTED_CHROMIUM_VERSION` build-arg for drift detection — see [[project_chromium_drift_warning_pattern]].

**Why:** PW 1.59.1 build request (#36) failed pre-fix because `CHS_REV=1223` default baked while SDK expected 1217.

**How to apply:** Adding ANY new browser-version-sensitive variant means threading the same chain. Skip a hop → silent launch-time `Executable doesn't exist`. The on-demand pre-flight is the only fast-fail; without it, build wastes 10+ min before failing at consumer COPY.
