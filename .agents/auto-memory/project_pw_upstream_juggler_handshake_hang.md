---
name: pw-upstream-juggler-handshake-hang
description: ROOT-CAUSED 2026-07-08. musl FF's Juggler XPCOM component-line-handler registers under category `m-remote`, colliding with Mozilla's RemoteAgent. JugglerFactory only instantiates as side-effect of RemoteAgent activating. Workaround: sed-inject `--remote-debugging-port=0` into PW test config so RemoteAgent wakes → Juggler activates. Real fix (pending): rename `m-remote` → `m-juggler` in juggler/components/components.conf via PW_JUGGLER_CATEGORY_RENAME=1 + FF rebuild.
metadata:
  type: project
---

**Root cause (verified 2026-07-08):** Juggler's XPCOM
component-line-handler registers under category name `m-remote`, which
collides with Mozilla's own RemoteAgent (same category). JugglerFactory
only instantiates as a side-effect of RemoteAgent activating. When PW's
fixture launches FF with only `-juggler-pipe`, Juggler stays dormant →
fd4 never writes "Juggler listening to the pipe" → launch times out at
whatever ceiling PW's fixture sets.

**Diagnostic path that got there:**
1. Docker-pulled the published `sha-90102ce27b28...` FF image, wrapped
   in a diag image with Alpine deps + nodejs (`/tmp/ff-repro`).
2. Confirmed `firefox.launch()` from PW SDK reproduces the hang locally
   (30s timeout, pid launched but no fd4 output).
3. Grep'd `playwright/alpine-browsers/firefox/smoke/launch.cjs` which
   already documents the workaround at lines 20-25 (`args:
   ['--remote-debugging-port=0']`) — the smoke-firefox job passes because
   of this arg. Compaction summary had misattributed the hang to a
   Firefox IPC channel error (`MessageChannel.cpp:2003`); actual
   `OnChannelErrorFromLink` events in MOZ_LOG are false positives
   ([[moz-log-ipc-false-positives]]).
4. Verified fix: `firefox.launch({ args: ['--remote-debugging-port=0']})`
   returns in 891ms, `page.goto` works.

**Landed workaround** (commit 72882f9): `conformance/run.sh` sed-injects
into `tests/library/playwright.config.ts`:
```
launchOptions: {
  executablePath,
  args: browserName === "firefox" ? ["--remote-debugging-port=0"] : undefined,
},
```

Local 1-spec verify: 26 pass / 1 real fail / 2 skip in 17.7s (was 11h
before). Full 10-shard: ~92% pass rate.

**Real source-side fix (pending, requires FF rebuild):** flip
`PW_JUGGLER_CATEGORY_RENAME=1` default in
`playwright/alpine-browsers/firefox/scripts/apply-and-build.sh` — that
already-present diagnostic renames `m-remote` → `m-juggler` in
`juggler/components/components.conf` so there's no collision. Then PW
upstream tests need no workaround arg.

**How to apply:** When investigating FF launch hangs on musl, DO NOT
grep MOZ_LOG for `OnChannelErrorFromLink` (those are noise —
[[moz-log-ipc-false-positives]]). Instead: (a) check whether smoke/
launch.cjs already documents a workaround, (b) reproduce locally in
Docker without CI, (c) test the workaround arg + verify Juggler
handshake completes.

Related:
- [[firefox-alpine-wip-pipeline]] — broader FF-on-Alpine context
- [[moz-log-ipc-false-positives]] — MOZ_LOG=ipc:5 noise trap
- [[ff-conformance-skip-seed-v1]] — resulting skip-list post-fix
