---
name: project_bench_reference_rows
description: The bench's reference row differs per environment on purpose — GHA compares to vm + manual install (the default thing a user does there), act compares to the official PW container because vm+install is too slow to mean anything, which is what the all-dashes row records
metadata:
  type: project
---

`benchmark-playwright.yml` uses a **different reference row per environment**,
and it is deliberate. The reference is "what would a user do here by default",
not "what is convenient to compare against".

- **GHA (hosted) tables → `vm + manual install`.** On `ubuntu-latest` the
  default is exactly that: a bare VM where you install node, pnpm, Playwright
  and the browsers yourself. Every image in the table is measured against the
  thing it replaces.
- **act tables → `official pw container`.** A from-scratch manual install inside
  nested act + DinD pays over 15 minutes for the apt unpack alone, so measuring
  against it would compare every row to a number nobody would ever accept. The
  official container is the realistic default there.

**The `> 15mn` / all-dashes `manual install` row in the act tables is not
missing data.** It is a deliberate placeholder recording a case that WAS
considered and rejected as too slow to carry meaning. Do not "fix" it by
dropping the row or by backfilling a measurement.

**How to apply:** when adding a column — `Δ execution %` was the case that
raised this — do not re-point it at a different reference because the current
one looks odd for that particular metric. I proposed exactly that (execution
compared to a VM that pulled its browsers from the CDN) and it was the wrong
instinct: the row answers "versus what you would otherwise do in this
environment", which is the same question for install cost and for execution
speed. One reference per table, chosen by environment.

Related: [[project_bench_execution_index]], and
[[feedback_bench_baseline_load_bearing]] — never drop the baseline arm.
