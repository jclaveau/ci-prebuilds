---
name: pw-webkit-inspector-pipe-crash
description: PW SDK launches MiniBrowser-wpe (`--inspector-pipe`) → WPEWebProcess crashes at +14s during page creation on our Alpine/musl WebKit build. Different layer than FF Juggler hang (#60) — WebKit can't even pass smoke
metadata:
  type: project
---

The `smoke-webkit` step's PW SDK path (`playwright.webkit.launch()` →
`newPage()`) is gated `if: false` because WPEWebProcess crashes during
page creation on our prebuilt.

**Symptom** (iters #15, #18, #19 — all identical pattern):
```
2026-06-20T13:43:20.857Z pw:protocol ◀ RECV
  {"method":"Target.targetDestroyed",
   "params":{"targetId":"page-7","crashed":true,...}}
```
- PW SDK sends `Target.createTarget` over `--inspector-pipe` (FD 3/4)
- WebKit reports `Target.targetCreated` for `page-7`
- ~+14s later, `Target.targetDestroyed {crashed:true}` for the same target
- `newPage()` never returns → all smoke/protocol tests blocked

**This is NOT the Firefox Juggler hang** ([[pw-upstream-juggler-handshake-hang]]):
- Firefox smoke + library-smoke PASS via PW SDK (8 Juggler RPCs work)
- Only PW's deep `tests/library/` framework hangs on FF
- WebKit's break is at the BASIC launch + page creation layer
- WebKit can't even reach Tier-2 smoke. FF can.

**What we tried (#15-#19) on the WebKit side** — none fixed it:
- InjectedBundle build target + path env (`WEBKIT_INJECTED_BUNDLE_PATH`)
- SIMDUTF ICELAKE (AVX-512) disabled at compile time (`-DSIMDUTF_IMPLEMENTATION_ICELAKE=0`)
- Mesa swrast runtime deps + `LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe`
- Full GStreamer/cairo/pango/gdk-pixbuf/dbus/opus/libsecret runtime deps
- Sandbox-strip layers: seccomp/apparmor unconfined + SYS_ADMIN/NET_ADMIN
  + `WEBKIT_FORCE_SANDBOX=0` + `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`

**Diagnostic step pivot** (#20-#23): tried isolating the crash from the
inspector-pipe handshake via `MiniBrowser-wpe --automation about:blank`
(no PW SDK, no inspector-pipe). Each iter hit a different Alpine
busybox shim quirk ([[alpine-busybox-gnu-shim-quirks]]) — burned 4
producer cycles on portability yak-shaving instead of the real bug.

**Iter #24**: reverted the diagnostic per [[revert-over-iterate]]. Producer
ships WPE+GTK binaries clean. Tier-2 PW SDK stays `if: false` with the
inspector-pipe wall doc'd inline.

**Where to dig** (next pickup):
- PW: `packages/playwright-core/src/server/webkit/wkConnection.ts` — the
  Node-side inspector-pipe wire handler.
- WebKit: `Source/WebKit/UIProcess/RemoteInspectorPipe.cpp` and
  `Source/WebKit/UIProcess/Inspector/BrowserInspectorPipe.cpp` —
  WebProcess-side. Page-creation path runs through here at +14s.
- The crash is likely musl/Alpine-specific (Microsoft's glibc prebuilt
  works fine for `playwright.webkit.launch()`).
- Local repro via `Dockerfile.wk-repro` (see session transcript): pull the
  `wk-sha-<rev>` image, install `playwright@1.60.0`, call
  `webkit.launch().then(b => b.newContext()).then(c => c.newPage())`,
  observe `Target.targetDestroyed {crashed:true}` at +14s.

Related:
- [[webkit-alpine-branch-c]] — overall WebKit pipeline design
- [[pw-upstream-juggler-handshake-hang]] — FF's analogous (but deeper)
  failure mode; reference for Tier-3 land-disabled pattern
- [[webkit-libwpe-bss-explicit-ctor]] — earlier libwpe musl wall fixed
- [[webkit-smoke-sandbox-strip-layers]] — sandbox env progression
