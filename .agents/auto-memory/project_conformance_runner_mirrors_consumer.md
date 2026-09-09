---
name: project_conformance_runner_mirrors_consumer
description: two ways conformance-webkit can go green while proving nothing — pw-conformance.yml builds its own runner (hand-mirrors the consumer's pw_run.sh, so a consumer-only preload is invisible) and the whole job is dispatch-gated off pull_request
metadata:
  type: project
---

Caught while gating PR #187 (zlib-ng screenshot fix) before merge — a green
`conformance-webkit` on the PR would have certified nothing about the change
actually shipping.

**Trap 1 — the runner is built from a PRODUCER artifact, and hand-mirrors
the consumer's wrapper rather than using it.**
`.github/workflows/pw-conformance.yml` builds via
`playwright/alpine-browsers/conformance/build-runner.sh`, which starts from
`alpine:edge` and only `COPY --from=${IMAGE_REF} /webkit …` — it never
consumes `playwright/Dockerfile.alpine`. Instead it re-implements the
consumer's `pw_run.sh` by hand: compiles fastfmod itself, apk-installs
mimalloc, writes its own `LD_PRELOAD` line. Any preload added ONLY in
`Dockerfile.alpine` (the zlib-ng entry in this case) is invisible to it —
same class of gap PR #181 already closed once for
`WEBKIT_SKIA_ENABLE_CPU_RENDERING`. Fix pattern: pull the interposition build
into ONE script (e.g. `build-zlib-ng.sh`) and have both `Dockerfile.alpine`
and `build-runner.sh` call it, rather than duplicating the recipe — a
duplicated recipe is exactly how the aports pkgver rule drifted in two of
three copies previously.

**Trap 2 — `conformance-webkit` doesn't run on `pull_request` at all.** It's
dispatch-gated. A fully green PR check bar can have zero webkit conformance
shards in it (23 non-skipped jobs, none of them webkit). Read the PR's own
producer/consumer run job list, not just the summary bar, before trusting
"conformance passed" as a merge gate for a webkit change.

**How to actually gate a webkit-runtime change:** dispatch
`pw-conformance.yml` explicitly with `--ref <branch>` (a dispatch runs the
workflow FILE from the given ref — off `main` it would build a runner
without your fix and tell you nothing useful), pass the current
`browser`/`image_ref`/`pw_version` (the `pw_version` input defaults to an old
pin — 1.60.0 in this repo's history — which silently exercises the wrong PW
client if left unset), then **grep the shard log for a non-vacuous marker**
proving the change was actually exercised (e.g. `zlib-ng smoke ok` /
`libz-ng-compat` — two hits confirmed the runner really carried the
preload), not just the job's pass/fail. Treat that dispatch, not the PR's own
checks, as the merge gate.

See [[project_wk_screenshot_is_alpine_os_libpng]] for the fix this validated
and [[project_vanilla_config_test_pw_alignment]] for the same
tested-version-mismatch shape elsewhere in the repo.
