---
name: project_wk_promote_gate_holds_the_nightly_bench
description: RESOLVED 2026-08-26 — the three conformance-webkit blockers were fixed and one dispatch off a COMBINED branch promoted wk-latest to ff0d9b55; GTK-off never blocked the promote
metadata:
  type: project
---

The chain that kept the nightly alpine 3-browser bench red for three nights:

```
3 red conformance-webkit shards
  -> conformance-webkit summary = failure
  -> promote-webkit skipped (it requires conformance success)
  -> wk-2336 / wk-latest stay hand-promoted pre-move builds
  -> the 3-browser alpine image ships a WebKit that cannot serve PW 1.62.1
  -> nightly benchmark-playwright alpine-*-all arms red every night
```

The three blockers and their fixes:

- shard 13 — `permissions.spec.ts camera and microphone` → PR #112, the
  UIProcess never consulted `Browser.grantPermissions`
  ([[project_wk_camera_mic_and_noxserver_dispositioned]]).
- shard 7 — `CacheStorage entry should survive page.reload()` → PR #116, PW's
  bootstrap.diff patches decode and not encode
  ([[project_wk_cachestorage_disk_records_invisible]]).
- shard 12 — `launcher.spec.ts no xserver` → PR #115, the suite now probes the
  artifact for a headed binary instead of assuming one
  ([[feedback_gate_on_measured_capability_not_skip_list]]).

**GTK-off never blocked the promote** — the gate reads only
finalize/smoke/conformance results. An earlier note claiming otherwise was
wrong.

**What actually shortened it.** Each fix landed on its own branch, and every
in-flight producer run predated the other two, so no single run could ever go
green. Merging all three onto ONE branch and dispatching that
(`build_webkit=true`) validated them together AND promoted, because
`promote-webkit` fires on any dispatch carrying the flag — not only on a push
to main. Run 32958171855: conformance summary success, promote success,
`wk-latest` and `wk-gtk-latest` at revision ff0d9b55. Reach for the combined
branch as soon as two fixes for one gate are in flight separately.
