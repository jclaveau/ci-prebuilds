---
name: project-sudo-requires-getpwuid
description: sudo refuses to run when the calling UID has no /etc/passwd entry — standard glibc + musl behavior, not Alpine-specific
metadata:
  type: project
---

`sudo` exits with `sudo: you do not exist in the passwd database` whenever the
calling UID has no NSS resolution. Affects every UID without an `/etc/passwd`
entry — anything outside the image's `0`/`1000`/`1001` (root/packer/runner).

**Why:** sudo calls `getpwuid()` early and bails if it returns `NULL`. Standard
glibc behavior on Ubuntu; standard musl behavior on Alpine — same outcome both
sides. Not an image bug, not Alpine-specific.

**How to apply:**

- For arbitrary-UID TP runs, either:
  - pick a UID that *does* have a passwd entry (1000 packer is the right
    choice, since 1001 is a GHA-side no-op — see [[project-gha-runner-uid-is-1001]]);
  - or accept that `sudo` won't work, layer `nss_wrapper` for the cosmetic
    fix on `whoami`/`$HOME`/`getpwuid()`-callers, and document the sudo gap
    (see [[project-nss-wrapper-scope]]).

- Debug clue: when an apparently-unrelated step fails with the "passwd database"
  line, root cause is "UID has no passwd entry", not anything in the workflow
  step itself.

The TP `Bind-mode arbitrary-UID via nss_wrapper` step deliberately omits the
`sudo true` assertion for this reason.
