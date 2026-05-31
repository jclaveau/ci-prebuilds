---
name: project-nss-wrapper-scope
description: nss_wrapper via LD_PRELOAD env fixes getpwuid/whoami/$HOME for arbitrary UIDs but NOT sudo (setuid strips LD_PRELOAD via AT_SECURE)
metadata:
  type: project
---

The image ships `nss_wrapper` + `/usr/local/bin/nss-wrapper-setup` (opt-in by
sourcing) so arbitrary host UIDs get a synthetic `runner` entry in a temp
passwd/group file. Cosmetic fixes work; sudo doesn't.

**Why sudo doesn't work:** `sudo` is setuid. glibc sets `AT_SECURE=1` for
setuid-executing processes and strips `LD_PRELOAD` before `dlopen`. The
wrapper's `.so` never loads inside sudo, so sudo's `getpwuid()` still returns
`NULL` → "you do not exist in the passwd database" (see
[[project-sudo-requires-getpwuid]]). Same outcome on musl (Alpine) for slightly
different mechanics.

**Scope A** (shipped — commit `d7cd178`):
- `libnss-wrapper` (Ubuntu) / `nss_wrapper` (Alpine) installed.
- `/usr/local/bin/nss-wrapper-setup` (inlined per [[project-docker-build-context-per-image]]).
- Sourcing the script exports `LD_PRELOAD`/`NSS_WRAPPER_PASSWD`/`NSS_WRAPPER_GROUP`
  and writes a synthetic `runner:x:$uid:$gid:…:/home/runner:/bin/bash` line.
- Fixes: `whoami`, `id -un`, `$HOME` fallback, `git`/`pnpm`/`node` `getpwuid()`.
- TP coverage: `Bind-mode arbitrary-UID via nss_wrapper` step (UID 5000).

**Scope B** (NOT shipped — Ubuntu-only, invasive):
- Add `/etc/ld.so.preload` line for `libnss_wrapper.so` (bypasses `AT_SECURE`).
- Add sudoers `Defaults env_keep += "NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP"`.
- Side effect: every binary on the image preloads the wrapper at startup.
- Alpine/musl: doesn't honour `/etc/ld.so.preload` for setuid the same way → no
  symmetric fix. Documented as a Ubuntu-only gap.

**How to apply:** when a user asks "how do I make sudo work as an arbitrary UID
under `act --bind`", surface this trade-off explicitly. Default: redirect them
to UID 1000/1001. Only walk through Scope B if they really need arbitrary +
sudo + Ubuntu and accept the global preload.
