---
name: project_wk_promote_unreachable_without_gtk
description: with build_webkit_gtk off (the default) the wk-gtk-sha artifact ships an EMPTY minibrowser-gtk, so conformance's headed leg cannot pass and promote-webkit can never fire
metadata:
  type: project
---

`promote-webkit` needs `conformance-webkit` green. `conformance-webkit` is fed
`wk-gtk-sha-<sha>` deliberately, "so the runner's `minibrowser-{wpe,gtk}/` is
complete", and it always runs `headful.spec.ts` as a headed leg — the `headed`
input only widens headed to the WHOLE suite, it does not gate that leg off.

But with `build_webkit_gtk` off (the DEFAULT — GTK is dispatch-gated), the gtk
round jobs skip and finalize publishes `wk-gtk-sha-<sha>` with an **empty**
`minibrowser-gtk/`. Measured on 0384a77a: 0 entries under `minibrowser-gtk/`,
131 under `minibrowser-wpe/`, no GTK MiniBrowser binary. The wpe-only
`wk-sha-<sha>` is equivalent for this purpose — swapping tags changes nothing.

So a default WebKit build fails 17 conformance tests it structurally cannot
pass (16 `headful.spec.ts` + `launcher.spec.ts`'s "no xserver" case), and
promote never fires. That is why [[project_webkit_strip_gtk_gate_promote]]
records `wk-2336`/`wk-latest` as having been "promoted manually" — the
automatic path has been unreachable, and hand-promotion hid it.

**How to apply:** do not read a red webkit conformance as a browser defect
until the headed cluster is subtracted. Three ways out, none yet taken: build
with `build_webkit_gtk=true` (but [[project_webkit_gtk_headed_recursion]] says
headed GTK crashes in libgtk-4 anyway), skip the headed leg when
`minibrowser-gtk/` is empty, or add the standalone `promote-webkit.yml` that
firefox and chromium-from-source both have and webkit does not.

Count entries, never trust the directory entry — `minibrowser-gtk/` is present
in the tar listing and holds nothing ([[feedback_complete_set_needs_the_real_artifact]]).
