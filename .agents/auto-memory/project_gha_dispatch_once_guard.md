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
