---
name: pnpm-chmod-eperm-upstream
description: SUPERSEDED 2026-09-24 — pnpm#3699 closed but unreleased, and moot on pnpm 12 anyway (isolated global tree per UID). Real wall under act --bind is 0755 dir ownership → ERR_PNPM_PNPM_DIR_NOT_WRITABLE, fixed image-side (PR #310) — but the first commit's fix AND its security claim were both wrong; testing found 3 more real defects (ancestor-walk clobber, alpine-gyp missing the helper, a baked `.links` FILE) before it actually worked for a consumer. See [[pnpm-real-wall-is-directory-ownership]].
metadata:
  type: project
---

**Original finding (pnpm ≤11, still accurate for that era):** `pnpm install -g <pkg>` under `act --bind --user $(id -u):$(id -g) --group-add 1001` on a `*-playwright[-gyp]` layer EPERMs with `chmod /home/runner/.local/share/pnpm/global/<v>/.pnpm/playwright@<v>/node_modules/playwright/cli.js`. Root cause: `linkBin` defensively `chmod 755`s every existing global bin during `install -g`; POSIX `chmod(2)` is owner-or-CAP_FOWNER only, and pre-baked bins are owned `runner:runner` from image build. Tracked at https://github.com/pnpm/pnpm/issues/3699 (open since 2021-08).

**2026-09-24 investigation (prompted by jean re: pnpm#3699 fix landing):**

1. **Upstream fix exists, not shipped.** PR https://github.com/pnpm/pnpm/pull/15281 merged 2026-09-22 20:45Z, but latest pnpm at check time was 12.6.0 published 17:08Z the same day — 3.5h *before* the merge. No release carries it yet.
2. **On pnpm 12 the original bug can't reproduce anyway.** pnpm 12 gives every `add -g` its own isolated tree `global/v11/<hash>` per invocation. Repro at 12.6.0: root pre-bakes `cowsay`+`json`, UID 5000 adds a third package — lands in its own hash dir, root's tree untouched, no chmod, no EPERM, `EXIT=0`. The chmod-EPERM shape was specific to pnpm ≤11's single shared global tree.
3. **Our actual wall today is a different bug, mis-documented as the same one.** Published `jclaveau/ubuntu-dood-playwright:latest` (pnpm 12.5.1), run `--user 5000:1001 -e HOME=/home/runner`:
   ```
   drwxr-xr-x 1001 1001 /home/runner/.local/share/pnpm{,/bin}
   drwxr-xr-x 1001 1001 /home/runner/.cache
   mkdir: … Permission denied
   Error: ERR_PNPM_PNPM_DIR_NOT_WRITABLE
   ```
   Plain 0755 directory ownership blocking `mkdir`, not `chmod(2)` on a file. `pnpm/README.md`'s "Known limit" section and the `TODO(pnpm#3699)` in `tests/act/smoke-dood-bind-arbitrary-uid.yml:32` both name the wrong cause.
4. **Image-side fix works today, no pnpm bump needed.** Probe layer: `chmod g+ws` on dirs / `g+w` on files for `$PNPM_HOME`, `~/.cache`, `~/.config` (+ create the two missing pnpm dirs at build time). Same 12.5.1 image: `sort-package-json 2.10.0` installs, `EXIT=0`. Playwright's own pre-baked bins stay 1001-owned and untouched — this fixes the *directory* creation path, not the old bin-chmod path.

**Trade-off to weigh before shipping:** `g+w` lets anything running as group `runner` overwrite pre-baked bins — previously read-only to non-owners. Inside our images only `runner` is in that group, and under act the consumer opts in explicitly via `--group-add 1001`. `g+s` (setgid) keeps new entries group-owned by `runner` so the property is inherited.

**Proposed change, jean said "go" 2026-09-24 (not yet applied as of this memory):**
1. `pnpm/Dockerfile` — add the `g+ws` pass after the pnpm install.
2. `tests/act/smoke-dood-bind-arbitrary-uid.yml` — uncomment the canary block, add a real `pnpm install -g` step (mkdir-canaries-only missed this bug for months).
3. `pnpm/README.md` — replace "Known limit": cause is directory ownership, fixed image-side, `-sudoer` flavour no longer needed for the act loop.
4. Untested: `/home/runner/playwright-browsers` under a consumer `playwright install` — same ownership shape, probably needs the same `g+ws` pass.

Superseded from the original memory: **don't try to fix it image-side** (no longer true — that verdict was reached against the chmod(2)-on-a-file problem, which a directory-permission pass can't touch; the *actual* current wall is a directory-permission problem, which it fixes). The PNPM_HOME split rejection ([[pnpm-home-split-design-rejected]]) and the `-sudoer`-gated `sudo chown` consumer workaround are both obsoleted by this fix once shipped.

Related: [[revert-over-iterate-on-structural-limits]] (the methodology applied to the original, now-superseded, diagnosis).

**2026-09-24 — shipped as PR #310, but the first commit was wrong twice
(one broken fix, one false security claim), both caught only by testing
the real path instead of a mkdir canary.**

Proven pre/post, act recipe's exact identity (`--user 5000:1001
--group-add 1001 -e HOME=/home/runner`), GHA's exact shell (`bash
--noprofile --norc -e -o pipefail`), script `regression-proof.sh`:

| step | pre-fix `ubuntu-dood-playwright:latest` | post-fix |
|---|---|---|
| state dirs writable by runner group | rc=1, `Permission denied` | rc=0 |
| `pnpm install -g` beside pre-baked tree | rc=1, `ERR_PNPM_PNPM_DIR_NOT_WRITABLE` | rc=0, `playwright --version` still works |

Three defects found only by testing the *consumer* path end to end, not
by re-running the mkdir canaries (which had passed for months while the
real scenario failed):

1. **Ancestor walk clobbered its own work.** The helper walked each dir's
   ancestors and reset them to `2775` unconditionally — so sharing
   `$PNPM_HOME/bin` after `$PNPM_HOME` reset `$PNPM_HOME` back toward
   `0755` (`drwxr-sr-x`, group write gone), and the second canary went
   red again. Fix: skip ancestors already shared (`find -perm -2020`);
   ancestors get `chown` + plain `0755` (traversal only, they don't need
   group-write themselves).
2. **`pnpm-gyp/Dockerfile.alpine` never got the helper**, yet
   `playwright/Dockerfile.alpine` (built FROM alpine `playwright-gyp`,
   which is FROM `pnpm-gyp`) calls `share-dir-with-runner-group` — a
   missing-command failure on that image, caught only by checking the
   alpine chain's base rather than assuming Dockerfile symmetry held.
3. **`~/playwright-browsers/.links/<hash>` is a baked FILE, not a dir**,
   that a real consumer `playwright install` opens for writing
   (`EACCES ... open '.../.links/05b33e44…'`) — the dirs-only rule (kept
   to avoid overlayfs copy-up of the ~1 GB browsers layer) missed it.
   Fixed anyway: 133 bytes, `g+w`'d in the same `RUN`, so no copy-up.
   Only found by actually running `playwright install` as the consumer
   UID — the `.act-bind-canary` mkdir probes never touch this path.

**The original security claim was also false, corrected in the same PR.**
Claimed baked bins (`0755 runner:runner`) stay safe from a foreign UID
because they're not group-writable. Wrong: **POSIX governs unlink/rename
by the *containing directory's* permission, not the file's** — with
`$PNPM_HOME/bin` now `2775`, group `runner` can `rm`/replace the baked
`playwright` shim regardless of the file's own mode. Proven: `rm
$PNPM_HOME/bin/playwright` — `Permission denied` pre-fix, succeeds
post-fix. A sticky bit would block that but ALSO block the legitimate
`pnpm install -g playwright@<newer>` upgrade path (verified working,
shim ends up owned by the consumer UID) — so the dirs stay `2775` and
the real, stated trade is: **anything holding group `runner` can create,
replace and delete in those dirs**, not just create.

Still failing for a consumer, by design or pre-existing (not bugs):
`--group-add 1001` omitted → unchanged EPERM (opt-in fix); `npm install
-g` → unaffected (`/usr/lib/node_modules` is root-owned and untouched,
use pnpm or `-sudoer`); `playwright install` on **alpine** → correctly
fails (`/ms-playwright` root-owned; alpine ships source-built browsers,
Playwright's own download is glibc-only anyway).

**How to apply:** for any "does this permission fix actually work"
question, a canary that only `mkdir`s/`rmdir`s a probe path is not
sufficient evidence — it missed all 3 defects above for months. Drive the
real consumer command (`pnpm install -g <pkg>`, `playwright install`) as
the real consumer UID before claiming a permission fix closes the gap.
And for any "is directory X safe to leave group-writable because the
files inside are read-only" reasoning, check unlink/rename, not just
open/write — POSIX puts that permission on the directory.
