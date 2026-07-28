---
name: tally-include-run-url
description: Iteration tally output must include the currently-running (or last-failed) GHA workflow run URL so user can jump to it directly without digging
metadata:
  type: feedback
---

When emitting an iteration tally (PR / build chain progress table), append the **current running** GHA workflow run URL at the bottom — or if no run is in_progress, the **most recent** run URL.

**Why:** User polls tallies many times per multi-hour build. Without the URL inline they have to gh-cli-list or open a browser tab manually. The tally already cites iter numbers — give them the click target too.

**How to apply:**
- Format: `Run: https://github.com/<owner>/<repo>/actions/runs/<id>` on its own line under the tally table (or as part of the "Next check" line).
- Pick: in_progress run first; else latest completed.
- One URL per tally — don't list all historical runs.
- Plain link, no markdown text label (so terminal/CLI users can paste directly).
- Branch name + commit SHA already implied by PR link; URL is the missing piece.
