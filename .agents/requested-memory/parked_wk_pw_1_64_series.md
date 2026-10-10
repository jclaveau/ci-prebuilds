---
name: parked_wk_pw_1_64_series
description: WebKit work for the next PW upgrade (1.63/1.64) — branch parked/wk-pw-1.64-series holds the 1e9d2b1f pin + the setAuthCredentials both-shapes shim; tag→base→rev map, the 2 protocol/pref breaks, what to redo on upgrade
metadata:
  type: project
---

jean 2026-10-09: "save all this work as we'll have to upgrade pw one day".
Reverted from main in d956f38 (scope = PW 1.62.1 browsers, see
[[feedback_goal_is_pw_1_62_1_browsers]]). Resume ONLY when PW_VERSION moves.

Branch `parked/wk-pw-1.64-series` (origin) = main at b5d11a6:
- 1df1d2e versions.env: PW_WEBKIT_PATCHES_REF=1e9d2b1ff186fd6bd592a8d5f967eb458132c9a9
  (base 56453fdfe0). Its bootstrap.diff is byte-identical to v1.64.0's.
- b5d11a6 prep-source.sh: patch_auth_credentials_both_shapes (Emulation.json +
  WebPageInspectorEmulationAgent.h/.cpp accept {credentials[]} AND
  {username,password,origin}). Only needed while the client is OLDER than the series.

| PW tag | WebKit base | webkit rev | setAuthCredentials |
|---|---|---|---|
| v1.62.1 | 343e13bf | 2336 (26.5) | username/password/origin |
| v1.63.0 | 4d05d732 | 2359 (26.6) | credentials array |
| v1.64.0 | 56453fdfe0 | 2370 (27.2) | credentials array |
Main's pair today: c377b7f / 4d05d732 (green 2026-10-06, run 37519378656).

Breaks seen when the series ran ahead of the 1.62.1 client (run 37841355978):
1. auth: httpCredentials, popup creds, proxy 407, client-certs ×3 hung (shape change).
2. storage.getDirectory: series forces FileSystemEnabled/HandleSerialization/
   WritableStream `default: true` on all platforms; 1.62.1 test expects TypeError off-Mac.

On the real upgrade (client + series moved TOGETHER): both breaks vanish — the shim
becomes dead code, drop it. Redo the checks in 1df1d2e's message: 0 failed hunks on
own base, prep-source.sh guards self-disable, project/so version asserts in
versions.env updated. Diff protocol.d.ts + wk*.ts between client tag and series ref
([[project_wk_1e9d2b1f_auth_protocol_skew]]).
Why moved: click_force 1.23x CPU vs official, llvmpipe compositing; the newer series
carries the Skia compositor work (DDL tiles, opaque layers w/o GL_BLEND, nearest
sampling). Never measured on CI (run 37863733126 cancelled).
