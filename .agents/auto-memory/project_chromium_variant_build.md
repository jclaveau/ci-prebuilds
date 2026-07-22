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
finalize→r14. Consumer smoke + headed conformance leg land once the artifact
finalizes (days).
[[project_headed_mode_support]] [[project_chromium_from_source_split_build]]
