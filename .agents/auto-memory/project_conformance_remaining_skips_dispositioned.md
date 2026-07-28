---
name: project_conformance_remaining_skips_dispositioned
description: Definitive disposition of ALL remaining conformance title-skips (2026-07-21 deep diagnosis) — chromium 6 / FF 5 / WK 4, zero file-skips. Only 2 are genuine Alpine gaps; rest are parity-contract or PW-intended-by-design. Don't re-investigate.
metadata:
  type: project
---

Deep-diagnosed every remaining title-skip 2026-07-21 (isolated on chs/ff/wk-prepared:
local). Result: **15 title-skips left (chromium 6, FF 5, WK 4), 0 file-skips.** Do NOT
re-open these — each is dispositioned:

**GENUINE Alpine-musl gaps — BOTH FIXED 2026-07-21 (no rebuild, runner/test-race):**
- WK `unicoderange` — NOT a WebKit gap: Modernizr uses `@font-face{src:local("Arial");
  unicode-range:U+0020,U+002E}`; Alpine had no Arial so it reported false. Fix:
  `font-liberation` in the WK runner (fontconfig aliases Arial→Liberation Sans). Un-skipped.
  See [[project_wk_webrtc_modernizr_resolved]].
- `trace-viewer › should filter actions by text` (chromium+FF) — UPSTREAM PW test race:
  `fullCount = actionTitles.count()` captured before the trace-derived action tree renders
  (searchbox renders faster) → 0 → `filtered < 0`. Browser renders + filters correctly.
  Fix: run.sh injects a `.action-title` waitFor before the baseline count. Un-skipped.
  → **Net genuine Alpine browser gaps across the whole suite: 0.**

**PARITY-CARRIED — pass on Alpine (xvfb) but MUST stay** (parity gate = Alpine skip-list ⊇
skip-list-ubuntu; these are in skip-list-ubuntu so removing them fails `check-skip-parity.sh`):
- chromium: `capture full viewport on hidpi`, `google.com frame with headed`, `page.pause when headed`
- FF: `support webgl`/`webgl 2 @smoke`/`work for webgl`, `page.pause when headed`
- WK: `should capture navigation` (black-frame, Ubuntu WK fails too), `page.pause when headed` (WK crashes launchServer+headed)

**PW-INTENDED (headless-shell-inapplicable by design, self-guarded upstream):**
- chromium `oopif re-connect to OOPIFs with CDP` (needs `channel:chromium`),
  `launcher headed-no-xserver friendly error` (shell is never headed).

**RECOVERED in this diagnosis (validated 20/20 under load, runs 29815617257 chromium +
29815618908 firefox):** chromium cli-codegen-1/2/3/aria + pause per-action partials (~12);
FF detach-child-frames/framesets/popover. All were stale (isolated-pass; the FF ones'
"load-flaky" restore predated the [[project_ff_juggler_pageerror_musl_gap]] fix).

**WK local-diag gotcha:** WK needs the FULL sandbox strip to launch in a plain container —
`--security-opt seccomp=unconfined --security-opt apparmor=unconfined --cap-add SYS_ADMIN
--cap-add NET_ADMIN -e WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 -e WEBKIT_FORCE_SANDBOX=0`.
Without it → `browserContext.newPage: Browser closed`. [[project_webkit_smoke_sandbox_strip_layers]]
[[project_ff_genuine_deltas_mostly_stale]] [[project_pw_conformance_scope]]
