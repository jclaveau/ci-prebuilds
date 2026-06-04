---
name: docker-mode-env-convention
description: ENV DOCKER_MODE=dind|dood baked into the dind/dood leaf overlays; inherits through every derived layer (node, pnpm, pnpm-gyp, playwright, -hardened). Consumers branch on env.DOCKER_MODE without socket-probing.
metadata:
  type: project
---

`dind/Dockerfile`, `dind/Dockerfile.alpine`, `dood/Dockerfile` set `ENV DOCKER_MODE=dind|dood` (shipped 9058d3d). Value propagates through every BASE_IMAGE-chained derived layer automatically. Smoke-tested in `tests/act/smoke-{dind,dood}.yml` (`test "$DOCKER_MODE" = "..."`).

Convention: UPPERCASE_SNAKE_CASE, `DOCKER_` prefix — matches existing `DOCKER_STORAGE_DRIVER` style. No collision with docker CLI's reserved env vars.

Consumers branch:
```yaml
if: env.DOCKER_MODE == 'dind'
```
or in shell:
```bash
[ "$DOCKER_MODE" = dind ] && start-dockerd
```

Documented in top-level README "two flavors" table + per-layer READMEs (dind/, dood/).

**Why this matters**: previously, consumers had to socket-probe (`[ -S /var/run/dind.sock ]`) or `pgrep dockerd`. `$DOCKER_HOST` is unreliable because `start-dockerd` deliberately doesn't write it to `$GITHUB_ENV` (dind/start-dockerd.sh:86-89 explains).
