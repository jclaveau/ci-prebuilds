---
name: project_wk_promote_gate_holds_the_nightly_bench
description: The nightly bench's alpine 3-browser arms are red because promote-webkit never fires; promote needs conformance-webkit green, and GTK-off is NOT the blocker — three named tests are
metadata:
  type: project
---

Chain, measured 2026-08-26:

```
3 red conformance-webkit shards
  -> conformance-webkit summary = failure
  -> promote-webkit skipped (it requires conformance success)
  -> wk-2336 / wk-latest stay hand-promoted pre-move builds
  -> the 3-browser alpine image ships a WebKit that cannot serve PW 1.62.1
  -> nightly benchmark-playwright alpine-*-all arms red every night
```

The bench failure surfaces as `Unknown setting: PushAPIEnabled` at
`newPage`, which is [[project_pw_webkit_base_lags_shipped_build]] one layer down.
`alpine-*-chromium` arms and every ubuntu baseline stay green — a clean
structural split, so it was never the bench harness.

**GTK-off does NOT block promote.** Run 32843700425 built with
`build-webkit-gtk-4` skipped and still got `build-webkit-finalize` and
`smoke-webkit` green with 17/20 conformance shards. An earlier note claiming the
promote was unreachable without GTK was wrong; the gate only reads
finalize/smoke/conformance results.

The three blockers:

- shard 13 — `permissions.spec.ts:364/:373/:386 camera and microphone`,
  what PR #112 fixes ([[project_wk_camera_mic_and_noxserver_dispositioned]]).
- shard 7 — `CacheStorage entry should survive page.reload()`, a real read-path
  bug ([[project_wk_cachestorage_disk_records_invisible]]).
- shard 12 — `launcher.spec.ts:45 no xserver` fails with
  `minibrowser-gtk/MiniBrowser: No such file or directory` because the test
  launches HEADED and GTK was not built. chromium already skips this exact title
  for the same reason (headless-shell has no headed binary), so a webkit skip
  would be the parallel move — jean's call, never skip unasked.

**How to apply:** fixing camera/mic alone does not green the bench. All three
shards must go green (or shard 12 be dispositioned) before a promote can ship a
1.62.1-capable WebKit. Do not "fix" the bench by skipping webkit there — jean
chose to wait for the real artifact, and the skip already exists in
`test-and-publish.yml` + `playwright.config.ts` but not in
`benchmark-playwright.yml`, which hardcodes `--project=webkit` at lines 163/229.
