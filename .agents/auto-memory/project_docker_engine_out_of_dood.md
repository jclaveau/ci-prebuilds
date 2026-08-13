---
name: docker-engine-out-of-dood
description: dood shipped a Docker daemon it can never use because dood/dind shared one base — moving the engine into dind cut alpine-dood-playwright 794 → 719 MiB
metadata:
  type: project
---

**dood talks to the HOST daemon over the bind-mounted socket and can never run a
local one, yet every dood image carried `docker-engine` + containerd** because
dood and dind both built on `<os>-docker`. Measured on alpine:edge:

```
docker-cli + docker-cli-compose        78 MiB
docker-engine + iptables (+containerd, runc)  +157 MiB   ← dead weight in dood
```

Fixed `36956ad`: the shared base installs CLI + Compose only; `iptables` and
`VOLUME /var/lib/docker` moved to dind with the daemon. On ubuntu, dind reads its
engine version back off the base's pinned `docker-ce-cli`
(`dpkg-query -W -f='${Version}' docker-ce-cli`) rather than re-declaring
`DOCKER_VERSION` — one place for Renovate to bump, no CLI/engine drift.

**Published result (compressed amd64):**

```
alpine-dood-playwright  794 → 719 MiB   (−75 MiB, −9.4%)
alpine-dood  72 MiB  vs  alpine-dind 125 MiB     → 53 MiB now dind-only
ubuntu-dood 173 MiB  vs  ubuntu-dind 263 MiB     → 90 MiB
```

**Why it mattered:** time-to-tests for a prebuilt image is ~entirely image pull —
install is ~1s because we bake everything — so the 299 MB docker layer was the
second-largest compressed blob, ahead of every browser.

**How to apply:** the docker group stays in the shared base (dood needs it to
reach the host socket, and it must exist before any docker postinst invents its
own GID). Verify a size claim with `imagetools inspect --raw` layer sums, not a
benchmark — the pull-time effect is far below CI noise
([[feedback_match_instrument_to_effect_size]]).

Related: [[project_strip_must_precede_final_copy]], [[project_dind_sudoers_paths_unmatched]].
