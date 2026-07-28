---
name: project_chromium_variant_build
description: The chromium from-source pipeline is parameterized by VARIANT (headless|headed) — headless=ninja headless_shell (default, byte-identical), headed=ninja chrome (full browser). How the knobs thread + the minimal-headed args + aports reference.
metadata:
  type: project
---

The chromium-headless-shell from-source pipeline builds EITHER
chrome-headless-shell OR full headed chrome via `VARIANT` (default `headless`).

**Single source of truth:** `scripts/variant-config.sh` maps VARIANT →
out-dir / ninja-target / binary / args-overlay / PW-layout / dist-bin. SOURCED
by apply-and-build.sh + ninja-resume.sh + stage-cache-layout.sh so they can't
drift. `Dockerfile.setup` bakes `ARG/ENV VARIANT` → flows through
Dockerfile.round + Dockerfile.finalize (both `FROM` the prior image, ENV
inherits — round/finalize need NO variant arg). `Dockerfile.finalize` takes
`ARG ARTIFACT_LAYOUT` for the scratch COPY (chrome-linux vs
chrome-headless-shell-linux64). Default headless keeps the existing build
byte-identical.

**headed = full `chrome` target.** Key insight: full chrome is a SUPERSET —
same binary runs headed (Ozone/X11 + GTK) OR headless (`--headless=new`).
`use_ozone`/`use_gtk`/extensions/pdf are ON by default under a desktop build;
you don't ADD headed, you stop SUBTRACTING it. Delta from headless_shell = the
`chrome` target + not-disabling the desktop features. Alpine's own chromium apk
proves full-chrome-on-musl works — aports `community/chromium/APKBUILD` is the
gn-args reference (chrome 150; our pin 148 → use cr148-* patch numbering).

**args.gn.headed.overlay = minimal-headed:** `chrome` target + explicit
`use_ozone/ozone_platform_x11/use_gtk` on, `is_official_build=false` (much
faster compile than aports' official build) + keep the lean cuts (no
webrtc/dawn/codecs/printing/audio). Heavier features re-enable per aports if a
headful test needs them. Extra runtime apk over headless: `gtk+3.0
mesa-dri-gallium font-opensans xdg-utils libudev`.

**Chain (LIVE):** setup → r1..r14 → finalize. r1 config validated green (run
29909366384); rounds r2..r14 added generous (chrome graph ≫ headless_shell's 8)
— spare rounds no-op fast once ninja is exhausted (cheaper than an undershoot
re-dispatch). finalize: `ninja chrome` no-timeout, BASE=chr-build-r14,
ARTIFACT_LAYOUT=chrome-linux, outputs chr-fs-sha-<sha> + chr-fs-edge, Tier-1
`chrome --version`. chr-* tag namespace, own concurrency bucket. pins query
browsers.json name=="chromium" (rev ≠ chromium-headless-shell path). WATCH the
BASE_IMAGE chain ([[project_multijob_base_image_audit]]) — audited rN→r{N-1},
finalize→r14.

**GREEN (2026-07-27):** headed artifact built — `chr-fs-edge` = Chromium
148.0.7778.96, Tier-1 smoke pass. Ninja exhausted ~r11 (r10 5h → r11 24min →
r12-14 no-op ~22min). **First finalize FAILED** (run 29946711140): the chrome
target references `printing::mojom::RequestPrintPreviewParams`
(print_preview_dialog_controller.h ← chrome_content_browser_client.cc)
unconditionally; the overlay had cut `enable_print_preview`/`enable_basic_printing`
as a stale lean-cut. `gn gen` passes, the last TU fails. Same "can't cut from
chrome" class as extensions/pdf. Fix: enable both in the overlay, keep
`use_cups=false` (print-to-PDF needs no CUPS backend; cups-dev in Dockerfile.setup
would cold-invalidate the whole chain).

**Warm-salvage pattern** (avoids a 2nd 5-day cold build) — `chromium-headed-finalize-warm.yml`,
dispatch-only, FROMs the existing r14 image directly (no round re-run),
delta-compiles only print-preview (~5452 edges, ~4h). Two bugs bit first:
(1) `Dockerfile.finalize` runs `/work/.../ninja-resume.sh` which is BAKED into
r14 at setup — a branch edit never reaches the container; fix = `COPY` the fresh
script over the baked one in finalize. (2) gn forbids reassigning an arg already
set in args.gn, so the patch must `sed`-REPLACE the baked `= false` lines, not
append. Gated by `PATCH_HEADED_PRINTING=1` (default off → clean path-A finalize
unaffected). TODO(headed-printing-cold-rebuild): once a clean rebuild from the
fixed overlay produces the artifact, drop the warm workflow + the gate.

**PENDING:** headed chromium conformance. build-runner.sh chromium branch stages
headless-shell + a fake `chrome-linux64/chrome` symlink — headed needs the REAL
`/chrome-linux` at PW's cache path; VERIFY dir name (`chrome-linux` vs
`chrome-linux64`, line ~64 suspicious) before dispatching pw-conformance
browser=chromium image_ref=chr-fs-edge headed=true. FF+WK headed already green.
[[project_headed_mode_support]] [[project_chromium_from_source_split_build]]
