---
name: chromium-151-gn-peel
description: chromium 151 gn gen needed two fixes, found by peeling one error at a time in the 10-minute setup job — enable_print_preview back ON, and pipewire-dev installed for //remoting's pkg_config
metadata:
  type: project
---

Bumping to chromium 151 broke `gn gen` in `build-chromium-headless-shell-from-source-setup`
(which runs with `PW_CHROMIUM_SKIP_NINJA=1`, so each iteration costs ~10-30 min,
not a build). Two blockers, peeled in order:

1. **`assert(enable_print_preview)`** at
   `//chrome/browser/ui/webui/print_preview/BUILD.gn:11`, reached via
   `//chrome/test:interactive_ui_tests`. Our headless overlay had it `false`.
   gn evaluates the whole `gn_all` graph, so it does not matter that
   `headless_shell` never links any of it. Fixed by setting
   `enable_basic_printing` + `enable_print_preview` back to `true` while keeping
   `use_cups = false` — `use_cups` is the knob that actually keeps cups out (it
   stops `//printing/BUILD.gn` shelling to `cups_config_helper.py`). Same
   combination the headed overlay already carried. aports sets neither, i.e.
   upstream default is enabled.
2. **`libpipewire-0.3` not found** — since 151, `//ui/display` pulls
   `//remoting/host/linux:x11_display_utils` whenever
   `is_linux && ozone_platform_x11 && enable_remoting`, and its
   `pkg_config("pipewire_config")` makes gn shell out to pkg-config. It sets
   `ignore_libs = true` (dlopen'd at runtime), so only the `.pc` file is needed.
   Fixed with `pipewire-dev` in `Dockerfile.setup`.

**Do NOT use `enable_remoting = false`** — a note in `args.gn.overlay` records it
starts a downstream assert chain. The usual "a new -dev package cold-invalidates
the round chain" objection did not apply because 151 had no rounds yet.

Round timings after it cleared: r1 32m, r2 44m, r3 10m, r4 9m — they accelerate
sharply once the heavy TUs are behind sccache.
