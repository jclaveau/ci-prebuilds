---
name: wk-pw162-requires-265
description: PW 1.62 cannot drive WebKit 26.4 (5017 conformance failures); our patched 26.5 build cuts that to 169, of which 168 are a strict subset — the residual is the PW bump, not our build
metadata:
  type: project
---

Discriminator run, same harness, same PW, only the artifact changed:

| artifact | PW | unique conformance failures |
|---|---|---|
| `wk-gtk-2287` (WebKit 26.4) | **1.62.0** | **5017** |
| ours, WebKit 26.5 + PushAPIEnabled patch | **1.62.0** | **169** |
| `wk-gtk-2287` (WebKit 26.4) | 1.60.0 | 0 |

```
only-old(26.4): 4849    both: 168    only-new(26.5): 1
```

**So the failures are the PW bump, and our rebuild is the repair, not the
cause.** 168 of our 169 are a strict subset of what 26.4 already fails under
1.62. Do not read a red WebKit conformance on 1.62 as a regression from our
patch without running this comparison — the "0 failures" baseline everyone
remembers was 26.4 under PW **1.60**.

Of the 169 residual:
- **16 are `headful.spec.ts`** — the artifact is WPE-only (`build_webkit_gtk`
  defaults false) so `minibrowser-gtk/` is empty and every headed launch dies.
  The green baseline used `wk-gtk-2287`, which had GTK. Config, not code.
- clusters: `defaultbrowsercontext-1/-2` 36, `page-close` 18,
  `browsercontext-storage-state` 10, `page-screenshot` 9. Error shapes are
  `browserType.launch(PersistentContext): Target page, context or browser has
  been closed`, `waitForEvent` timeouts, `browser.newContext: Test ended`.
- **exactly one failure is unique to our build**, and unexamined:
  `tests/library/heap.spec.ts:191:5 › should not leak dispatchers after closing page`
  — worth its own look, since a dispatcher leak is the shape a protocol-surface
  patch could plausibly cause.

Related: [[project_pw_webkit_base_lags_shipped_build]], [[project_conformance_remaining_skips_dispositioned]].
