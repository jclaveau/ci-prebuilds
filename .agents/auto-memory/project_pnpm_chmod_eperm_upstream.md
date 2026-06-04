---
name: pnpm-chmod-eperm-upstream
description: pnpm install -g re-`chmod`s every existing global bin via linkBin; POSIX chmod(2) is owner-or-root so a non-1001 host UID under act-bind EPERMs on pre-baked playwright/cli.js. Tracked upstream pnpm/pnpm#3699. Image-side fixes don't work; consumer workaround is sudo chown gated by env.ACT == 'true' (requires -sudoer flavor under act).
metadata:
  type: project
---

Symptom: `pnpm install -g <pkg>` under `act --bind --user $(id -u):$(id -g) --group-add 1001` on a `*-playwright[-gyp]` layer EPERMs with `chmod /home/runner/.local/share/pnpm/global/<v>/.pnpm/playwright@<v>/node_modules/playwright/cli.js`.

Root cause: pnpm's `linkBin` defensively `chmod 755`s every existing global bin during `install -g`. POSIX `chmod(2)` requires the caller to be the inode owner (or CAP_FOWNER); mode bits, ACLs, supplementary groups do NOT grant chmod rights. Pre-baked bins are owned `runner:runner` from image build; host UID isn't `runner`. → EPERM.

**Don't try to fix it image-side.** Both attempts failed:
- Recursive `2775 g+w` chmod on PNPM_HOME (commit c447caf, reverted in 64579d9): fixes write/mkdir, NOT chmod.
- Split PNPM_HOME (runtime canonical empty + PNPM_HOME_BUILD for baked tools): considered, rejected — shared store would re-expose the trap on transitive-dep dedup (yargs/semver/etc. owned by image-build runner). See [[pnpm-home-split-design-rejected]].

**The fix lives upstream**: https://github.com/pnpm/pnpm/issues/3699 (open since 2021-08, maintainer-acknowledged, `linkBin` is the call site per aghArdeshir's repro).

**Until upstream lands**, the consumer's workflow does:
```yaml
- if: ${{ env.ACT == 'true' }}
  run: sudo chown -R $(id -u):$(id -g) /home/runner/.local /home/runner/.cache
```
Requires the `-sudoer` image flavor under act (`:latest` is hardened and strips broad sudo).

Documented in `pnpm/README.md` "Known limit" section. Dead-code TODO markers in `tests/act/smoke-dood-bind-arbitrary-uid.yml` and `.github/workflows/test-and-publish.yml` (test-dood-pnpm-act job, commented out).

Related: [[revert-over-iterate-on-structural-limits]] (the methodology applied here).
