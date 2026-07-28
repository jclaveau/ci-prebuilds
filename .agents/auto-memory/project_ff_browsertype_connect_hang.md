---
name: ff-browsertype-connect-hang
description: FF browsertype-connect run-server HANG was PW filterLaunchOptions stripping the musl Juggler arg — RESOLVED 2026-07-20 by wrapping the FF binary to inject --remote-debugging-port=0 server-side (no security-filter change). Un-skipped + validated.
metadata:
  type: project
---

**RESOLVED 2026-07-20 — binary wrapper (jean's idea), no security change.** The
FF conformance runner now wraps the FF binary (conformance/build-runner.sh):
`mv firefox firefox.real` + a tiny `firefox` sh-wrapper that injects
`--remote-debugging-port=0` (dedup-guarded) before `exec firefox.real "$@"`. The
arg is now ALWAYS on the command line regardless of PW's `filterLaunchOptions`
stripping client args on the run-server path — so PW's RCE-prevention filter stays
FULLY intact (we did NOT patch it). Un-skipped `browsertype-connect.spec.ts` +
reconnect/wss titles + the FF & WK remote-video titles. Validated: browsertype-
connect green across shards (run 29732802155, 19-20/20; the lone shard-6 red was
an unrelated frame-lifecycle flake). REJECTED alternative: an investigation agent
proposed patching PlaywrightServer.filterLaunchOptions to let args through under
isUnderTest() — that weakens the RCE control; the wrapper achieves the same with
zero security change. See [[feedback_unskip_regression_beyond_target]] +
[[project_conformance_structural_was_stale]].

--- original diagnosis kept below ---

`tests/library/browsertype-connect.spec.ts` = PW's remote-browser-server path:
`browserType.launchServer()` exposes a `ws://` endpoint, `connect(wsEndpoint)`
drives it over the network (browser grids, cloud providers, browser-in-a-
container). NOT the local `firefox.launch()` case this image actually ships.

**Verdict: OUT OF SCOPE for now, fix-later.** jean 2026-07-17: "mark it as out
of scope for now but it would be nice to dig deeper to fix it later."

**Why:** BUCKET-C PROBE (iter 29565116253) un-skipped the whole file keeping the
6 structural titles (reconnect/wss/ipv6×2/headed) grep-inverted — FF conformance
shard 6 HUNG 38min+ (vs ~2-4min normal) instead of clean-failing. The hang
reaches PAST the 6 named titles → title-level grep-invert can't contain it →
whole-file skip is load-bearing. A hanging shard is worse than missing coverage.
Root cause UNCONFIRMED (did NOT even prove shard-6 == this file).

**ROOT CAUSE CONFIRMED 2026-07-20 (local repro, ff-prepared).** The hang is the
`run-server` KIND, not `launchServer`. The musl FF needs the
`--remote-debugging-port=0` arg (wakes RemoteAgent → Juggler; else dormant → the
handshake hang, see [[pw-upstream-juggler-handshake-hang]]). For the
`launchServer` kind the arg reaches the browser (works). For the `run-server`
kind (`cli.js run-server` → `PlaywrightServer`), PW's `filterLaunchOptions()` in
`packages/playwright-core/src/remote/playwrightServer.ts` STRIPS all client-
supplied launch `args` — an RCE-prevention control (a remote client must not
inject arbitrary browser args). So the Juggler workaround arg is filtered out →
run-server FF launches WITHOUT it → Juggler dormant → every run-server subtest
TIMES OUT → the "38min hang".

**Fix is a SECURITY decision (NOT auto-applied).** filterLaunchOptions already
lets `executablePath`/`artifactsDir` through under `isUnderTest()`
(PWTEST_UNDER_TEST=1). Extending that gate to `args` (a one-line run.sh sed on the
runner's PW-core clone, test-harness-only, not shipped in any artifact) unblocks
the hang — validated locally, no hangs, 82/112+ passing. BUT it weakens an
RCE-prevention control, so it needs explicit authorization. Non-weakening
alternatives: (a) fix the musl FF Juggler/RemoteAgent handshake at BUILD time so
the `--remote-debugging-port=0` workaround isn't needed at all (deep, the real
fix); (b) keep skipped (the filter is doing its job; our workaround is the
problem). Pending jean's call.

**How to apply:** keep the whole-file skip until the security call is made.
Related: [[pw-conformance-scope-out-of-scope]],
[[pw-upstream-juggler-handshake-hang]], [[project_conformance_structural_was_stale]].
