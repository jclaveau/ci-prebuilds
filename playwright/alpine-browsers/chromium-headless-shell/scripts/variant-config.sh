#!/usr/bin/env sh
# Resolve VARIANT → the build knobs the chromium from-source pipeline threads
# through apply-and-build.sh, ninja-resume.sh, and stage-cache-layout.sh.
# Single source of the mapping so the three scripts can't drift.
#
#   headless (default) — chrome-headless-shell: `ninja headless_shell`, the
#                        minimal CDP-only binary. PW auto-discovery path
#                        chromium_headless_shell-<rev>/chrome-headless-shell-linux64/.
#   headed             — full chrome: `ninja chrome`, the real headed browser
#                        (Ozone/X11 + GTK window). PW path
#                        chromium-<rev>/chrome-linux/chrome.
#
# SOURCED (not executed) — sets VARIANT_* vars in the caller's shell.

VARIANT="${VARIANT:-headless}"
case "$VARIANT" in
  headless)
    VARIANT_OUT_DIR="out/headless"
    VARIANT_TARGET="headless_shell"
    VARIANT_BIN="headless_shell"
    VARIANT_OVERLAY="args.gn.overlay"
    VARIANT_LAYOUT="chrome-headless-shell-linux64"
    # PW expects the binary renamed to chrome-headless-shell.
    VARIANT_DIST_BIN="chrome-headless-shell"
    ;;
  headed)
    VARIANT_OUT_DIR="out/headed"
    VARIANT_TARGET="chrome"
    VARIANT_BIN="chrome"
    VARIANT_OVERLAY="args.gn.headed.overlay"
    VARIANT_LAYOUT="chrome-linux"
    # PW expects the full chromium binary named `chrome` (no rename).
    VARIANT_DIST_BIN="chrome"
    ;;
  *)
    echo "ERROR: VARIANT must be 'headless' or 'headed' (got: '$VARIANT')" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac
export VARIANT VARIANT_OUT_DIR VARIANT_TARGET VARIANT_BIN \
       VARIANT_OVERLAY VARIANT_LAYOUT VARIANT_DIST_BIN
echo "  VARIANT=$VARIANT → target=$VARIANT_TARGET out=$VARIANT_OUT_DIR layout=$VARIANT_LAYOUT"
