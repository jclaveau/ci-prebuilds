---
name: project_wk_smoke_camera_needs_pw162
description: the webkit smoke's getUserMedia assertion fails as "Unknown permission: camera" because the job runs PW 1.60 — the permission only exists in PW's webkit map from 1.62
metadata:
  type: project
---

Run **32476690483** (`fix/webkit-residual-patches`) built for 11.5 h and the
smoke failed on:

    browserContext.newPage: Unknown permission: camera
        at /smoke/launch.cjs:107:44

**It is a Playwright version artifact, not a browser gap and not a bad test.**
`grantPermissions(['camera','microphone'])` is applied lazily at page creation
by `wkPage.ts`, which is why it surfaces on `newPage`, and the throw comes from
Playwright's own `webPermissionToProtocol` map:

| PW | webkit map has camera/microphone |
|---|---|
| 1.60.0 | **no** |
| 1.62.1 | yes (`wkPage.ts:1242-3`) |

The smoke job runs `PW_VERSION: 1.60.0`. Same root blocker as main's red
version assert: the repo is pinned to 1.60 while the new work targets 1.62.1
([[project_ff_rev_has_no_renovate_manager]]).

**Everything else in that smoke passed, including the fix under test:**
`OK : right click event order (got: ["mousedown","contextmenu","mouseup"])` —
PR #98's contextmenu fix is validated on a real build.

Two reasoning traps this cost:
- "It surfaced at `newPage`, so the BROWSER rejected it" is wrong — permissions
  are applied at page creation, so the client throws there too.
- `browser.version()` printed `26.4` and means nothing: it is a hardcoded
  playwright-core constant ([[project_webkit_version_assertions]]).

No `ALPINE-DIAG` markers appeared in the smoke log (0 occurrences), so the
diagnostic those patches carry is still unvalidated by this run.

**How to apply:** do not weaken or skip the camera assertion — it is correct
for the version we are moving to. It passes once PW 1.62.1 lands.
