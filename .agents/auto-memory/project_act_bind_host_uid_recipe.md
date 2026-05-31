---
name: project-act-bind-host-uid-recipe
description: Canonical container-options recipe for running this repo's dood images under `act --bind` without leaving 1001-owned files on the host
metadata:
  type: project
---

Run dood images under `act --bind` with:

```
--container-options "--user $(id -u):$(id -g) --group-add 1001 -e HOME=/home/runner"
```

i.e. drop privileges to the host UID/GID, keep group `1001` (= image's `runner`) so
group-mode sudoers + `/home/runner` (`0775`) + `/opt/hostedtoolcache` (`2775`, SGID)
stay writable, and pin `$HOME` so tools don't fall back to `/`.

**Why:** `act --bind` bind-mounts the workspace, so by default everything is
written as the image `USER` (`runner`, UID 1001) and lands on the host owned by
1001 → ownership friction for any host user ≠ 1001. The recipe sidesteps this
without rebuilding the image and without `act --copy` overhead.

**How to apply:** any time the user runs `act --bind` locally against
`jclaveau/ubuntu-dood` or `jclaveau/alpine-dood` and complains about host-side
ownership. Also: the local mirror is `pnpm act:smoke` (post-implementation of
[[plan-prompt-saving-wrappers]]).

Composes with the image-side changes:
- `%runner ALL=(ALL) NOPASSWD:ALL` (group sudoers, in `/etc/sudoers.d/runner`)
- `chmod 0775 /home/runner` (so non-1001 supplementary-group members can write)
- `chmod 2775 /opt/hostedtoolcache` (SGID → tool-cache writes inherit `runner` group)

For UIDs without a `/etc/passwd` entry (anything other than 0/1000/1001), see
[[project-nss-wrapper-scope]]; for the TP-side test pattern that exercises this,
see [[project-tp-bind-test-pattern]] and [[project-gha-runner-uid-is-1001]].
