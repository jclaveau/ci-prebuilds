---
name: wk_ssp_costs_nothing
description: WebKit pays no measurable price for Alpine's stack-protector — 233,941 canary loads removed, every row unchanged; do NOT ship the flag, and do not reuse chromium's +12% as a prior
metadata:
  type: project
---

Alpine's clang forces `-fstack-protector-strong` from the driver, and our shipped
libWPEWebKit carried **233 941 canary loads against Playwright's ZERO** at
near-identical instruction counts (23.99M vs 24.65M, run 34139683751). Removing
it with `-Xclang -stack-protector -Xclang 0` bought **nothing**:

| row | SSP parity | ThinLTO only |
|---|---|---|
| `layout` | 0.79 | 0.80 |
| `dom_churn` | 0.94 | 0.95 |
| `goto_cold` | 1.11 | 1.12 |
| `eval_rtt` | 1.13 | 1.13 |
| `click_force` | 1.24 | 1.23 |
| `launch` | 1.34 | 1.35 |

n=10, one machine, one job (run 34160320006). The arm was verified to carry the
change end to end: the build asserted 0 canaries on the linked library, and the
ELF audit re-read `canary-loads: 0` / `stack-chk-refs: 0` on the *probed
consumer image* (run 34161543437), so this is a real negative and not a null
arm.

**Why:** chromium measured the same tax at **+12.0% instructions** on a
call-dense kernel, which made "webkit pays it too" look obvious — 9.75 canary
loads per 1k instructions is not a small number. It is still not a cost:
canary loads hit L1-hot stack slots and predict perfectly, so on webkit's hot
paths they disappear into the shadow of everything else. A static count of an
instruction is not a measurement of its price, however large the count is.

**How to apply:** do not ship the flag — it is a hardening reduction with no
benefit, and unlike chromium (whose reference is the *weak* variant, so parity
means 1, never 0) webkit's reference is 0, which makes the temptation stronger.
Do not carry chromium's +12% across as a prior for any other binary either.
And when `click_force` / `eval_rtt` / `goto_cold` get another candidate cause,
it is not this one: [[project_wk_launch_is_the_loader]] and a differential
`perf record` profile are the live leads. See [[project_alpine_clang_forces_ssp_strong]]
for the flag mechanics, which remain correct.
