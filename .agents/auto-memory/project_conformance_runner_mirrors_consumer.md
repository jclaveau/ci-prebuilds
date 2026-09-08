---
name: project_conformance_runner_mirrors_consumer
description: build-runner.sh hand-mirrors Dockerfile.alpine's pw_run.sh, so a preload added only in the consumer is invisible to conformance — and conformance-webkit does NOT run on a pull_request
metadata:
  type: project
---

Two independent traps that together let a runtime change ship completely
unvalidated. Both bit on PR #187 and were caught before merge.

**1. The conformance runner does not use the consumer image.**
`pw-conformance.yml` builds its own runner via
`playwright/alpine-browsers/conformance/build-runner.sh`, which starts from
`alpine:edge` and `COPY --from=${IMAGE_REF} /webkit` out of a **producer**
artifact. It never reads `playwright/Dockerfile.alpine` — it **hand-mirrors**
it: compiles fastfmod from source, apk-installs `mimalloc2-insecure`, then
writes its own `pw_run.sh` with its own `LD_PRELOAD` line. So anything added
only to the consumer wrapper is invisible, and conformance goes green on a
browser we do not ship. Same class as the gap #181 closed for
`WEBKIT_SKIA_ENABLE_CPU_RENDERING` (which needed `EXTRA_ENV` in the workflow).

**2. `conformance-webkit` does NOT run on a `pull_request`** — it is
dispatch-gated. The PR's producer run had 23 non-skipped jobs and not one was a
webkit shard, so a fully green PR check bar proves nothing about the browser.

**How to apply:** when adding anything to webkit's `pw_run.sh` (a preload, an
env var), change `build-runner.sh` in the same commit, and prefer a shared
script both callers run over an inline `RUN` duplicated twice — the aports
pkgver rule drifted in two of three copies exactly that way
([[project_aports_pkgver_rule_drift]]). `webkit/probes/run-probe.sh` mirrors the
env block too.

Then gate the merge on an explicit dispatch, **with `--ref <your branch>`** — a
dispatch runs the workflow FILE from the given ref, and off `main` it would
build a runner without your change and tell you nothing:

    gh workflow run pw-conformance.yml --ref <branch> \
      -f browser=webkit -f image_ref=ghcr.io/jclaveau/playwright-alpine-browsers:wk-<rev> \
      -f pw_version=1.62.1 -f artifact_rev=<rev>

`pw_version` defaults to **1.60.0**; pass the real one. Then prove the run was
not vacuous by grepping a shard log for your artifact (for zlib-ng:
`zlib-ng smoke ok` and `libz-ng-compat`).

Also add a `paths-ignore` negation in `test-and-publish.yml` for any new
directory under `playwright/alpine-browsers/` that the CONSUMER compiles — the
whole tree is ignored, with negations for `fastfmod/**`, `zlib-ng/**` and
`strip-bundled-libs.sh`. Without it the change lands on main and never reaches a
published image ([[project_tp_paths_ignore_ships_nothing]]).
