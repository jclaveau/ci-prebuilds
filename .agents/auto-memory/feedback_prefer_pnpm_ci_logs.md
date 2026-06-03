---
name: prefer-pnpm-ci-logs
description: For fetching failing-job logs in this repo, prefer `pnpm ci:logs` (no args, auto-finds latest failed job in latest run) over a direct `gh api .../jobs/<id>/logs` call.
metadata:
  type: feedback
---

When diagnosing a CI failure in this repo, **call `pnpm ci:logs` first** — it auto-detects the most
recent failed job in the most recent run, dumps the cleaned tail. Only fall back to `gh api`/manual
URL chasing when targeting a *non-latest* failure or a specific job by ID that the script can't find.

**Why:** raw `gh api .../jobs/<id>/logs` calls trigger a permission prompt each time (different URL
each call), which fragments the user's workflow. `pnpm ci:logs` is a single fixed command — once
allow-listed it never prompts again, and it does the common case (latest failure tail) inline.

**How to apply:**
- After `pnpm ci:watch` fires with `--- $label first failure: <jobname> ---` → next call is
  `pnpm ci:logs` (not a `gh api .../logs` URL).
- If the user wants a specific older job's log (not the latest failure), the script doesn't cover that
  — you may need raw `gh api` then; but for the standard fail-watch loop, default to the script.

See also: [[autonomous-ci-loop]] for the surrounding amend+push+watch pattern.
