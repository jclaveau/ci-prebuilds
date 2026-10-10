---
name: project_gha_run_block_expression_length_limit
description: a `run:` step containing any `${{ }}` is parsed as ONE GitHub Actions expression, capped at 21000 chars — a large inline python/bash block silently kills the whole workflow dispatch
metadata:
  type: project
---

`gh workflow run benchmark-playwright.yml` failed to even start with
"Exceeded max expression length 21000 (Line: 443, Col: 14)" — the daily push
run (35614947372) died the same way at parse time, before any job ran. Cause:
the `summary` job's `run:` block embedded a large python script and used one
`${{ matrix.x }}`-style expression inside it; GitHub Actions treats an entire
`run:` block as a single expression once it contains any `${{ }}`, and caps
that at 21000 characters — the block was 26.6 KB.

Fixed in PR #283 by moving the python out to a checked-in file
(`playwright/bench/bench-summary.py`), fetched via a sparse checkout in that
job, and shrinking the `run:` step to just `python3 bench-summary.py`.

**How to apply:** any workflow step that both (a) embeds a sizeable inline
script and (b) references any `${{ }}` context expression anywhere in that
same `run:` block is at risk — move the script to a repo file and read
context via `env:` instead of interpolating it inline, once the block gets
past a few hundred lines.
