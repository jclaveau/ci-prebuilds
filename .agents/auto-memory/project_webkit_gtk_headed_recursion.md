---
name: webkit-gtk-headed-recursion
description: RESOLVED 2026-07-22 — headed MiniBrowser-gtk SIGSEGV (libgtk-4 self-recursion at newPage) was the artifact's hand-assembled bundled gtk4 stack, NOT GTK4-on-musl or WebKit. Fix — bundle-dist drops the gtk4 closure for the GTK port so the consumer's consistent `apk add gtk4.0` supplies it. Tier-2 headed smoke re-enabled.
metadata:
  type: project
---

**RESOLVED 2026-07-22 — root cause = the bundled gtk4 stack, not GTK4/WebKit.**
Discriminator chain (local, `wk-prepared`):
- A **standalone** GTK4 window (`apk gtk4.0-4.22.4` + pygobject) realizes fine
  under the same Xvfb-Alpine → NOT a generic GTK4-on-musl-Xvfb bug.
- The bundled libgtk-4 is the SAME version (4.22.4) as the working apk one →
  NOT a gtk4 version issue.
- Reproduced the crash in `wk-prepared` (headed `newPage` → "Target closed").
  Forcing the runner's apk gtk4 over the bundle via `LD_LIBRARY_PATH=/usr/lib`
  (RUNPATH=`$ORIGIN` loses to LD_LIBRARY_PATH) → **PAGE+GOTO OK**. So the flat
  ldd-walk **bundle** is the culprit: it mixes libs from different apk states,
  and a version-skewed member of the gtk4 stack drives libgtk-4 into infinite
  self-recursion (bottoming through glib `g_get_monotonic_time`). glib-only
  swap did NOT fix it — the whole gtk4 stack must be consistent.

**Fix (validated locally, no WebKit rebuild logic changed):**
`webkit/scripts/bundle-dist.sh` — for the **GTK port only**, exclude libgtk-4's
own ldd-closure (glib/gobject/gio, pango, cairo, gdk-pixbuf, graphene, epoxy,
harfbuzz, X11/wayland, fontconfig, freetype, …, ~107 libs) from the bundle.
The consumer's single consistent `apk add gtk4.0` supplies that closure.
Everything else stays bundled — WebKit-built libs AND webkit media/font apk
libs (gstreamer, icu, avif, webp, enchant) — so the consumer needs ONLY
gtk4.0, nothing more. WPE (headless) is untouched (links no gtk4, fully
self-contained). Producer smoke Tier-2 headed re-enabled (dropped `if: false`).
Consumer-image `apk add gtk4.0` + a WK headed conformance leg are the
follow-ons once the smoke confirms the fix in a rebuild.
Sibling of [[feedback_diagnose_before_accepting_cant_fix]] — the "GTK4-on-musl
event-loop quirk" verdict below was a hypothesis; the real cause was cheap.

---

**Original diagnosis (kept for the backtrace evidence — hypotheses now
superseded by the RESOLVED section above):**

The headed launch path through `pw_run.sh` dispatches to MiniBrowser-gtk
(the GTK4 build of MiniBrowser). On Alpine/musl under Xvfb (no compositor,
no GPU), MiniBrowser-gtk crashes with **SIGSEGV from stack overflow / infinite
recursion in libgtk-4.so.1** during the PW SDK newPage call.

**Identified by** smoke-webkit-iter run **28155027218** (tier-2-headed mode):

```
launch.cjs (with {headless:false}):
OK  : webkit.launch({headless:false}) returned a browser
OK  : browser.newContext()
[no newPage OK — process crashed]
launch-headed.cjs rc=1
<process did exit: exitCode=139, signal=null>     # 139 = 128+11 = SIGSEGV
```

**Core dump bt** (post-mortem gdb, binary auto-detected from core's
recorded exe path):
```
#0  g_get_monotonic_time_ns ()           libglib-2.0.so.0
#1  g_get_monotonic_time ()              libglib-2.0.so.0
#2  ??                                   libgtk-4.so.1 [+0x900257]
#3  ??                                   libgtk-4.so.1 [+0x900257]   ← same PC
#4  ??                                   libgtk-4.so.1 [+0x900257]   ← same PC
... (~30 identical frames) ...
```

The recursion is *inside libgtk-4*, not WebKit. WebKit code is never
reached on the headed path. So the bug is GTK4-event-loop-on-musl-under-
Xvfb, separate from anything in our WebKit build pipeline.

**Likely causes** (one of):
- Xvfb without a compositor → GTK4 measure/allocate loop never terminates
  (a widget reports a different preferred size each pass)
- musl `clock_monotonic` resolution interacts badly with GLib's main-loop
  scheduling (the recursion gates on `g_get_monotonic_time` which is the
  first frame to drop into glib)
- Some Alpine package incompatibility between gtk4.0 and the WebKit-built
  artifact (we use Alpine's apk-shipped gtk4.0 runtime; the build links
  against the same)

**Workaround for now**: Tier-2 headed step in the producer's smoke-webkit
job is gated `if: false`. WPE Tier-2 (headless, --inspector-pipe →
MiniBrowser-wpe) is the validated path and what production CI consumers
will hit. Headed/GTK is "if possible" per the original goal.

**Where to dig next** (not in current PR scope):
- Reproduce locally with `wk-edge` image + Xvfb tuned (`-screen 0 ... -ac
  +iglx`, `-noreset`, `-nolisten tcp`)
- Try Wayland/Weston instead of Xvfb
- Strip MiniBrowser-gtk symbols → run under `gdb -ex 'info symbol 0x...'`
  to identify the recursing function
- Cross-reference with WebKitGTK upstream issues for "gtk_widget_measure
  recursion" on Linux
- A standalone GTK4 "hello world" under Xvfb-Alpine — if THAT crashes,
  it's not a WebKit problem at all, just GTK4-on-musl-Xvfb.

**Diagnostic infra** (reusable for next dig):
- smoke-webkit-iter workflow with `tier=tier-2-headed` mode
- Post-mortem gdb uses `file <core>` to extract exe path → picks
  minibrowser-gtk/ vs minibrowser-wpe/ automatically
- `sudo chmod -R a+rX /tmp/cores` lets actions/upload-artifact read
  root-owned cores

Related:
- [[webkit-alpine-branch-c]] — overall pipeline (WPE Tier-2 green)
- [[webkit-fortify-source-skia-trap]] — separate WebKit-internal fix
  that landed the headless path
- [[pw-upstream-juggler-handshake-hang]] — FF #60 land-disabled template
