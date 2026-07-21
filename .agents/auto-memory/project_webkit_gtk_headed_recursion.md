---
name: webkit-gtk-headed-recursion
description: PW SDK headed launch on Alpine/musl crashes MiniBrowser-gtk inside libgtk-4 with what looks like infinite recursion (~30 identical-PC frames in gtk widget code) at newPage time; WebKit code never runs. Tier-2 headed gated `if: false` in the producer smoke until the GTK4-on-musl event-loop quirk is identified.
metadata:
  type: project
---

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
