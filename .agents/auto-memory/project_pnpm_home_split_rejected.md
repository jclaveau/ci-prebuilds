---
name: pnpm-home-split-design-rejected
description: We considered splitting PNPM_HOME (runtime canonical empty + PNPM_HOME_BUILD for image-baked tools) to dodge the chmod-EPERM trap. Rejected because shared store deduplicates on transitive-dep bins; image-built ones are owned runner and would still EPERM via pnpm linkBin during a runtime install of a different package.
metadata:
  type: project
---

The design that was considered + REJECTED:
- `ENV PNPM_HOME=/home/runner/.local/share/pnpm` (runtime, empty at end-of-build)
- `ENV PNPM_HOME_BUILD=/home/runner/.local/share/pnpm-docker-build` (where image-build pnpm installs land)
- `ENV PATH="${PATH}:${PNPM_HOME}:${PNPM_HOME_BUILD}"`
- Each image-build `pnpm install -g <X>` wrapped with `PNPM_HOME=${PNPM_HOME_BUILD} XDG_CACHE_HOME=... XDG_CONFIG_HOME=... pnpm ...`

Why rejected: pnpm at runtime walks ONLY its own PNPM_HOME's manifest (so it doesn't re-chmod playwright in PNPM_HOME_BUILD), BUT transitive-dep deduplication still hits the trap. A consumer `pnpm add -g wait-port` whose tree contains `yargs`/`semver`/`mkdirp`/etc. → pnpm hardlinks from existing store inodes (owned `runner` from image-build playwright install) → pnpm's `linkBin` defensively chmods those bins → EPERM. Smaller blast radius than the original bug, not zero.

Sharing the store between build and runtime PNPM_HOMEs has the same problem (hardlinks share inode ownership).

**Don't re-propose unless**: pnpm fixes the defensive chmod in `linkBin` (pnpm/pnpm#3699 lands), OR a dedup-skip-with-safe-ownership mechanism lands.

Shipped state: single PNPM_HOME, no image-side perm trickery (reverted 64579d9), consumer workaround documented in [[pnpm-chmod-eperm-upstream]].
