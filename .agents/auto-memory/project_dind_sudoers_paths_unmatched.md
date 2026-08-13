---
name: dind-sudoers-paths-unmatched
description: dind's narrow sudoers named /usr/sbin/dockerd and /usr/bin/chown — paths that don't exist on Alpine — so the rules never matched; only the hardened flavour would have exposed it
metadata:
  type: project
---

**sudo matches a rule against the ABSOLUTE path it resolves a command to, so a
rule naming a path the binary doesn't occupy simply never matches — silently.**

`dind/Dockerfile*` hardcoded five paths. On Alpine three were wrong:

```
dockerd  /usr/bin/dockerd   (rule said /usr/sbin/dockerd)   — also wrong on ubuntu
chown    /bin/chown         (rule said /usr/bin/chown)      — busybox applet
chmod    /bin/chmod         (rule said /usr/bin/chmod)      — busybox applet
docker, tee  /usr/bin/…     ✓
```

Nothing ever failed, because every non-hardened flavour still carries a broad
NOPASSWD that covers the calls. **The narrow rules exist only for the hardened
flavour, which strips that** — so the single configuration these lines were
written for is the one where they would not have worked.

**Fixed `be33f7e`:** resolve with `command -v` at build time and interpolate, with
an `-x` guard so a future package move fails the build instead of quietly
re-opening the hole. Verified on alpine:edge — `visudo -c` parses it and the rule
names the real paths. `start-dockerd.sh` calls `sudo dockerd` (PATH-resolved), so
the generated path is what sudo will actually compare.

**How to apply:** never hardcode a binary path in a sudoers rule that spans two
distros. More generally — a guard that can only be exercised in a configuration
you rarely build is a guard you have never tested; check it against that
configuration explicitly, not against the default flavour.

Related: [[project_docker_engine_out_of_dood]], [[project_sudo_requires_getpwuid]].
