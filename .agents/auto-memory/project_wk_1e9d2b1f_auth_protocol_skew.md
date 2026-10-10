---
name: project_wk_1e9d2b1f_auth_protocol_skew
description: WebKit on PW 1e9d2b1f patches breaks httpCredentials/proxy-auth/client-cert under the 1.62.1 client — Emulation.setAuthCredentials changed shape; run 37841355978 shards 7+13 red, wk-latest not promoted; move REVERTED d956f38
metadata:
  type: project
---

1df1d2e moved PW_WEBKIT_PATCHES_REF to 1e9d2b1f (WebKit 56453fdfe0). In that
bootstrap.diff, `Emulation.setAuthCredentials` takes `{credentials: AuthCredentials[]}`.
The PW 1.62.1 client (the version we pin) still sends `{username, password, origin}`
(wkPage.ts:756 v1.62.1 vs :763 1e9d2b1f). The browser reads `credentials` as
missing, which means "automation auth off", so every challenge hangs.

Run 37841355978 (c79ef7b) had conformance-webkit shards 7 and 13 red with 7 tests:
- defaultbrowsercontext-1 httpCredentials
- popup inherit http credentials
- proxy CONNECT 407 reconnect
- client-certificates ×3: no-cert, http2, rejected-cert-http2
- capabilities storage.getDirectory. This one is different: test version skew,
  not a bug. On the new WebKit, Linux also returns UnknownError, and the test
  only expects that on Mac. Upstream relaxed the test after 1.62.1.

**Why:** the patch series is the browser↔client wire protocol, not only codegen. Moving
PATCHES_REF ahead of the pinned client version can change the protocol shape.
**How to apply:** before bumping PW_WEBKIT_PATCHES_REF, diff
`packages/playwright-core/src/server/webkit/protocol.d.ts` + `wk*.ts` between the client
tag and the patches ref. Every changed command shape needs a back-compat hunk in
prep-source.sh (accept both shapes), or a revert. b5d11a6 shimmed it (patch_auth_credentials_both_shapes), but both commits were REVERTED in d956f38 (2026-10-09): the move itself was scope drift ([[feedback_goal_is_pw_1_62_1_browsers]]). The work is kept for the next PW upgrade, see [[parked_wk_pw_1_64_series]]. Never skip a test ([[feedback_never_skip_conformance_tests]]).
Side note: the conformance build-runner.sh "command substitution: syntax error" + tar
error is pre-existing noise from backticks in a comment inside an unquoted heredoc
(~line 405-413, since 656c1ab, 09-07). It is not a cause of anything.
Related: [[project_pw_patch_series_base_pairing]], [[project_wk_closepage_hang]].
