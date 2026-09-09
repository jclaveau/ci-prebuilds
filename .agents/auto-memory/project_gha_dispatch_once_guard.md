---
name: project_gha_dispatch_once_guard
description: a lost `gh workflow run` reply is not a failed dispatch — it already executed server-side; scripts/dispatch-once.sh refuses when a run is live on the ref and confirms by watching for a NEW run id rather than believing the POST
metadata:
  type: project
---

The project instance of [[feedback_idempotent_remote_launch]], which is worth
its own note here because the cost is asymmetric and this repo's expensive
dispatches are the ones most likely to be retried.

**2026-08-27:** `gh workflow run chromium-gap-probes.yml` returned
`net/http: TLS handshake timeout`. The POST had already landed; the retry fired
a second run (33086348928 and 33086596884, same inputs). Harmless on an
informational probe. The same mistake on `playwright-alpine-browsers.yml` with
`build_chromium_headless_shell_from_source=true` costs a full chromium chain of
runner time and produces two arms nobody asked for.

`scripts/dispatch-once.sh <workflow-file> <ref> [-f k=v ...]` has two guards
because they catch different failures:

- **Before:** refuse if a run for that workflow is already `queued` or
  `in_progress` on that ref. That is the "my retry already landed" case, and it
  is also the "someone else is already running this arm" case.
- **After:** poll for a run id that did NOT exist before the POST, rather than
  trusting the POST's exit code. This also sidesteps
  [[reference_gh_run_watch_wrong_id]] — `gh run list --limit 1` straight after
  a dispatch routinely returns the PREVIOUS still-finishing run, so latching
  onto it watches the wrong thing.

The POST is deliberately allowed to fail without the caller retrying: whether it
took is decided by looking for the run, not by the reply. Exit 3 = refused
because one is live; exit 4 = genuinely did not land, safe to retry (and the
before-guard will catch it if that judgement was wrong).

**Use it for anything that costs more than a few minutes** — the from-source
chromium chain, webkit builds, firefox builds. Probes can stay on plain
`gh workflow run`.

**Two more failure modes hit in one session (2026-09-08), both about trusting
the guard's own confirmation step too literally:**

- The after-guard's "watch for a new run id" poll itself hit
  `api.github.com` connection errors partway through and reported "the
  dispatch did NOT land" for a run that, checked by hand, had. The guard's
  confirmation can fail for the same transient-network reasons the dispatch
  itself can — a negative reply means "could not confirm," not "did not
  happen." Verify by listing runs before retrying a guard that just said no,
  especially before an expensive build.
- The reverse mistake: a run id that appeared right after a dispatch attempt
  was assumed to BE the dispatch, when it was actually an unrelated
  `pull_request` run retriggered by a force-push to the same branch's PR
  (webkit jobs skip on `pull_request`). Checking the found run's event type
  (`workflow_dispatch` vs `pull_request`), not just its existence or recency,
  is what caught it.

**The guard is scoped per-REF, not per-inputs.** A second dispatch of the
same workflow on the same ref but with different `-f` inputs (e.g. a second
`wk-perf-record.yml` run with a different `kernel=`) gets refused by the
before-guard even though `perf-probe.yml`'s own concurrency key is the
image, not the ref, so the two genuinely wouldn't collide. When the inputs
differ, dispatch directly with `gh workflow run` and confirm a NEW run id
appeared by hand (`gh run list`, filter on created-at) instead of routing
through the guard.

**`gh pr checks`-style watchers: an in-progress check has an EMPTY
conclusion, not `null`/`PENDING`.** A hand-rolled poll that pattern-matches
conclusion strings for "still running" can declare victory on its first poll
against a job that hasn't even started. Use `gh pr checks`' own exit code
(8 = pending, per its docs) as the pending signal instead of parsing
conclusion fields — a purpose-built exit code doesn't have this trap.

**A backgrounded shell that itself backgrounds the real job (`nohup script &`
or `script &` inside a `run_in_background: true` call) never notifies.** The
harness-tracked task exits immediately once the outer shell returns, and the
inner `&` job's completion is invisible to it — happened twice in one
session. Invoke the actual long-running script directly with
`run_in_background: true`, don't wrap it in a second layer of
backgrounding.
