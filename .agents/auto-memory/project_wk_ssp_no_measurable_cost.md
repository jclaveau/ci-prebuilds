---
name: project_wk_ssp_no_measurable_cost
description: the stack-protector-strong tax that costs chromium +12% instructions was measured on WebKit too, exact parity (233,941 canaries -> 0) verified end-to-end on the probed artifact, and it changed NOTHING — not shipped
metadata:
  type: project
---

Same driver-forced `-fstack-protector-strong` behaviour documented in
[[project_alpine_clang_forces_ssp_strong]] (chromium: +12.0% instructions on a
call-dense kernel) was also present on WebKit: **233,941** canary loads in
`libWPEWebKit-2.0.so.1` against official's **0**. Built a parity arm with
`-Xclang -stack-protector -Xclang 1` (weak, matching official — same fix
chromium used, level 1 not `-fno-stack-protector`), consumer image built
green, smoke + conformance both passed.

**Verified on the artifact, not the recipe, before trusting the result**
([[feedback_verify_ab_varied_the_variable]]): the probed image itself read
`canary-loads: 0` / `stack-chk-refs: 0` — exact parity.

**The A/B (n=10, same machine, SSP-parity vs ThinLTO-only control) came back
flat on every row:**

| row | SSP parity | ThinLTO-only control |
|---|---|---|
| `layout` | 0.79 | 0.80 |
| `dom_churn` | 0.94 | 0.95 |
| `context_page` | 0.95 | 0.95 |
| `goto_warm` | 1.01 | 1.03 |
| `goto_cold` | 1.11 | 1.12 |
| `eval_rtt` | 1.13 | 1.13 |
| `click_force` | 1.24 | 1.23 |
| `launch` | 1.34 | 1.35 |

Removing all 233,941 canary loads bought nothing, within noise on every row.
**Not shipped** — it is a hardening reduction with zero measured benefit, so
there is no case for taking it. Unlike chromium, WebKit's stack-protector
posture is not on the critical path.

This also **kills the working explanation** for `click_force` / `eval_rtt` /
`goto_cold` — they now have no candidate cause. Next instrument queued is a
differential `perf record` on the WebProcess (ours vs official, one runner,
symbol tables diffed), the same kind of instrument that cracked chromium's
screenshot row after static candidates ran out
([[project_chromium_screenshot_is_skia_highp]]). Recorded together with the
[[project_wk_launch_is_the_loader]] DT_RELR negative result in PR #171.
