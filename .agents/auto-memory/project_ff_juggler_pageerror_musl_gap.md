---
name: ff-juggler-pageerror-musl-gap
description: FF page-event-pageerror cluster (~22 tests) fails on Alpine/musl with a client-side `Cannot read properties of undefined (reading 'url')` + "Test ended" — deep Juggler/musl error-surfacing gap, fix location uncertain, NOT fired as a speculative rebuild.
metadata:
  type: project
---

FF `tests/page/page-event-pageerror.spec.ts` cluster (`pageErrors should work`,
`clearPageErrors should work`, `should contain the Error.name property`,
weberror/console/exception-stack siblings — ~22 titles) stays skipped. The attack
queue predicted a narrow Juggler Runtime.js/PageAgent.js null-guard patch + a 2h
`build_firefox` rebuild. **Probed 2026-07-19 — NOT that simple; did NOT build.**

Local probe (ff-prepared, juggler `--remote-debugging-port=0`): every case fails
with `TypeError: Cannot read properties of undefined (reading 'url')` followed by
`Test ended` — even the single-error `should contain the Error.name property`
(not just the 301-error flood). The crash is **client-side** (PW-core reading
`.url` on an undefined location while processing the pageUncaughtError event), not
a clean assertion-string mismatch.

Why NOT patched: the obvious Juggler dig-site is CLEAN — `content/Runtime.js`
consoleServiceListener (lines 127-172) already guards `executionContext`
(`if (!executionContext) return`) and its `url: message.sourceName` is a plain
string. So the gap is NOT there. It's some combination of: the musl FF binary
emitting `nsIScriptError` with `outerWindowID==0` (→ the `!message.outerWindowID`
guard drops the error → PW `waitForEvent('pageerror')` gets nothing / a malformed
event) and/or PW-core's own `.url` read (upstream, not patchable in this repo).
The fix location is uncertain and spans Juggler + the FF binary + possibly
upstream PW-core — unverifiable without a 2h FF rebuild per iteration. Per the
"don't fire a build on an unverifiable guess" rule, documented structural.

**Dig-sites (if attacked later, on a throwaway branch):** (1) in the musl FF
build, log `message.outerWindowID` / `message.sourceName` in
`juggler/content/Runtime.js` observe() to confirm whether the error is even
reaching Juggler; (2) if it IS emitted, capture the exact `pageUncaughtError`
payload vs what PW-core `packages/playwright-core/src/server/firefox` expects for
`.url`; (3) only then decide a Juggler payload fix vs an upstream PW report.
Related: [[project_ff_conformance_skip_seed_v1]],
[[feedback_unskip_regression_beyond_target]],
[[project_pw_upstream_juggler_handshake_hang]].
