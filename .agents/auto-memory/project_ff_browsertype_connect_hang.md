---
name: ff-browsertype-connect-hang
description: FF browsertype-connect.spec.ts (remote-browser-server launchServer/connect) HANGS a conformance shard 38min+ on musl; marked out-of-scope with a fix-later TODO
metadata:
  type: project
---

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

**How to apply:** keep the whole-file skip in `firefox.files.txt` (the wired-up
TODO with dig-sites lives in its comment). WebSockets themselves are fine on
FF-musl (page `new WebSocket()` + Juggler control both pass) — the failure is
specific to the launchServer/connect proxy, possibly in PW's Node-side WS server
not FF. Dig-sites when picked up: (1) confirm shard-6 attribution; (2) single-
spec local repro via conformance/run.sh; (3) bisect launchServer WS spawn vs
reconnect loop vs video/artifactsDir sub-tests. Related:
[[pw-conformance-scope-out-of-scope]], [[pw-upstream-juggler-handshake-hang]].
