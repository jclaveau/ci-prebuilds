---
name: project_ff_ship_path_push_and_iter_flake
description: Canonical FF ship path is push-to-main — build-firefox (if push) + promote-firefox (if push && main) both fire on a merge push, so a merged PR auto-builds+promotes ff-latest with NO manual dispatch. A workflow_dispatch builds but promote-firefox is push-gated → never ships ff-latest. Also: choose_iter can flake to cold on a transient manifest-inspect despite a valid base.
metadata:
  type: project
---

`playwright-alpine-browsers.yml` FF job gates (verify in-tree before relying):
- `build-firefox` `if:` = `push` **OR** `(workflow_dispatch && build_firefox=='true')`
  **OR** `(pull_request && label 'build-firefox')`.
- `promote-firefox` `if:` = `github.event_name == 'push' && ref == main` ONLY.
  Copies the GHCR `sha-<gitsha>` build → Docker Hub + GHCR `ff-latest`.

**Consequence:** a merge to main IS the ship path. The merge push auto-runs
build-firefox + promote-firefox → patched `ff-latest`, unattended. A separate
`gh workflow run ... -f build_firefox=true` is REDUNDANT after merge — it builds
+ smoke-tests but promote-firefox is push-gated, so it `skipped` and ff-latest
never moves. (2026-07-28: I dispatched redundantly, then watched that
non-promoting run ~4h; the real ship was the merge-push run 30360426989, iter
~10min → promote → patched `ff-latest` at 12:56Z.)

**choose_iter cold-flake:** two identical-input runs on the SAME merge SHA +
same base + same hash `d175458bf183` took DIFFERENT paths — push run = iter
(~10min), my dispatch = cold (~4h). choose_iter fail-safes to the cold full
Dockerfile when its `docker manifest inspect $BASE_TAG` errors (transient GHCR
blip), even though the base exists. Not a fix bug (hash matched, base pushed).
Cold still ships correct output: cold uses the patched `apply-and-build.sh`, so
ff-latest is patched either path — cold just costs ~3-4h vs ~10min.

Confirms [[project_ff_prebuilt_base_pin_only_tag_staleness]] fix WORKS
end-to-end (PR #81 merged 0baf9cec). [[feedback_watch_merge_push_run_not_dispatch]]
[[project_ff_latest_stale_no_edge_tag]]
