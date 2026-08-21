---
name: wk_premove_build_needs_old_pw
description: a pre-base-move WebKit artifact hangs at newPage() under a newer Playwright, so pre/post A/B cannot hold the client constant
metadata:
  type: project
---

`wk-latest` / `wk-26.5` / `wk-2336` (sha `2c40565`, 2026-08-13, WebKit
`343e13bf` era) driven by `playwright@1.62.1` **launches fine and then hangs
forever at `newPage()`** — the `PushAPIEnabled` protocol-setting mismatch that
motivated the base move in the first place ([[project_pw_webkit_base_lags_shipped_build]]).

So a "did the base move regress X?" A/B **cannot** be run by pointing one
Playwright at both artifacts: each build only works with its contemporary
client, and pairing them varies browser *and* client together.

**Why:** 2026-08-19 I pulled the 692 MB pre-move payload onto a disk at 96% and
built a runner around it, only to hit the hang at +0.6s. The incompatibility was
already recorded; I did not check it before spending the pull.

**How to apply:** before probing an archived browser artifact, check which PW
version it was built for and pin the client to that. If the question needs one
client across both, it is not answerable that way — reach for a source-level
diff between the two WebKit revisions instead.

Runner recipe (payload images are `FROM scratch`, no shell): copy the heredoc
`Dockerfile.runner` out of `playwright-alpine-browsers.yml`'s conformance job —
alpine + the apk list + `COPY --from=<payload> /webkit /opt/playwright/webkit-<REV>`
+ `touch INSTALLATION_COMPLETE` + `npm i -g playwright@<VER>`. `playwright-core`
is nested under the global `playwright`, so require `playwright` with
`NODE_PATH=/usr/local/lib/node_modules`.
