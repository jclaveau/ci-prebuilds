---
name: ff-juggler-pageerror-musl-gap
description: RESOLVED 2026-07-20 — FF page-event-pageerror crash-family (26 titles) fixed by threading `location` through Juggler Page.uncaughtError; run 29745047841 conformance-firefox all-20-shards green with the 26 un-skipped.
metadata:
  type: project
---

**RESOLVED 2026-07-20 (commit ef541ad, run 29745047841 all-20-shards green).**
Root cause was NOT musl error-surfacing — it was a Juggler protocol GAP: v1.60.0
juggler omitted `location` from the `Page.uncaughtError` event, but the v1.60.0
CLIENT (`browserContextDispatcher.ts:117`) reads `pageError.location.url`
UNCONDITIONALLY → `Cannot read properties of undefined (reading 'url')` client-side
crash on every page-level uncaught error → "Test ended" → cascade. Fix (ports
upstream `main`): patch juggler `Runtime.js` to build
`errorLocation = {lineNumber, columnNumber, url: message.sourceName}` and thread it
through `onErrorFromWorker`/`_onRuntimeError`; add `location` param in `PageAgent.js`;
add `location: runtimeTypes.ScriptLocation` to `Protocol.js` uncaughtError. Applied as
a python3 heredoc in `firefox/scripts/apply-and-build.sh` (after the juggler cp).
The un-skipped `weberror event should include location` title passing is direct proof.
26 crash-family titles recovered → FF conformance ~95.3% → higher.

--- ORIGINAL DIAGNOSIS (kept for the dig-site method) ---

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

**The crash CASCADES (2026-07-20 sharded probe, run 29706652835).** Un-skipping
all 86 non-shared FF titles at once: 7/20 shards went FULLY green (a real stale
subset exists among the 90) but 13/20 red. The `.url`-undefined crash fires,
prints "Test ended", and kills the worker's REMAINING tests → one crash ripples
into many failures. So the FF delta is NOT ~90 independent gaps; it's this
cascade PLUS diverse genuine musl deltas (browsercontext-fetch/base-url,
har-transferSize, CORS/CSP error-strings, cross-process/Fission). The cascade
makes the stale subset non-isolable from line-reporter logs — reverted to the
90-skip / 95.3% baseline. To recover FF further: fix the pageerror crash FIRST
(then re-probe; many "genuine" fails are just cascade victims), OR parse the
per-shard HTML report artifacts (exact per-test pass/fail) instead of logs.

**Dig-sites (if attacked later, on a throwaway branch):** (1) in the musl FF
build, log `message.outerWindowID` / `message.sourceName` in
`juggler/content/Runtime.js` observe() to confirm whether the error is even
reaching Juggler; (2) if it IS emitted, capture the exact `pageUncaughtError`
payload vs what PW-core `packages/playwright-core/src/server/firefox` expects for
`.url`; (3) only then decide a Juggler payload fix vs an upstream PW report.
Related: [[project_ff_conformance_skip_seed_v1]],
[[feedback_unskip_regression_beyond_target]],
[[project_pw_upstream_juggler_handshake_hang]].

**SUPERSEDED UPSTREAM at PW 1.62 (2026-08-13).** v1.62.0's
`juggler/content/Runtime.js` builds `errorLocation` itself, three lines below our
anchor — so the port's asserts fired with `anchor not found` ten seconds into the
first 1.62 build. Fixed `65bc655` by **detecting the fix rather than the version**
(`'const errorLocation = {' in Runtime.js` → skip), so the patch still applies to
older pins, no-ops forward, and a tree with NEITHER the fix nor the anchor still
fails loudly. Verified against both real juggler trees: 1.60.0 → APPLY,
1.62.0 → SKIP. Generalises: a port whose own comment says "ports upstream main"
has an expiry date — guard it on the presence of what it adds.
