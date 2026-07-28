#!/usr/bin/env bash
# Make a staged WebKit MiniBrowser dist self-contained:
#   - copy transitive system .so deps into <dist>/ (excluding universal-runtime
#     libs that MUST resolve from the consumer's base)
#   - patchelf RPATH=$ORIGIN on both MiniBrowser + every bundled .so (flat layout)
# Result: artifact runs on any musl base regardless of system lib version drift.
#
# Usage: bundle-dist.sh <port_dir>
# Expects: <port_dir>/MiniBrowser  (built binary, flat layout per PW pw_run.sh)
#          <port_dir>/*.so         (WebKit's primary .so set, alongside binary)
# Mutates <port_dir> in place.
#
# The exclusion list + ldd-walk + patchelf passes mirror firefox/scripts/
# bundle-dist.sh; same musl-ABI rationale (loader+libc must come from the
# consumer's base or dynamic linker state corrupts).

set -euo pipefail

DST="${1:?usage: bundle-dist.sh <port_dir>}"
[ -d "$DST" ] || { echo "bundle-dist: $DST is not a directory" >&2; exit 1; }
[ -x "$DST/MiniBrowser" ] || { echo "bundle-dist: $DST/MiniBrowser is not executable" >&2; exit 1; }

echo "===== Bundling .so deps + patchelf RPATH for $(basename "$DST") ====="

EXCLUDE_LIBS="ld-musl-x86_64.so.1 libc.musl-x86_64.so.1 libgcc_s.so.1 libstdc++.so.6"

# The GTK (headed) port must NOT bundle the gtk4 stack. A hand-assembled flat
# ldd-walk snapshot mixes libs from whatever apk state each transitive dep was
# pulled at; a version-skewed member drives libgtk-4 into an infinite
# self-recursion at window-realize (SIGSEGV in the WebProcess at newPage —
# WebKit code never runs). Letting the consumer's single consistent
# `apk add gtk4.0` closure supply that whole stack fixes it (validated locally:
# excluding the gtk4 closure + apk gtk4.0 → headed newPage+goto green).
#
# We exclude ONLY libgtk-4's own runtime closure (glib/gobject/gio, pango,
# cairo, gdk-pixbuf, graphene, epoxy, harfbuzz, X11/wayland, fontconfig,
# freetype, …), computed from the build image's system libgtk-4. Everything
# else stays bundled: the WebKit-built libs (libwebkit2gtk, JavaScriptCore,
# injected bundles) AND the webkit media/font apk libs (gstreamer, icu, avif,
# webp, enchant, …) — so the consumer only needs `apk add gtk4.0`, nothing
# more. WPE (headless) is untouched: it links no gtk4 and stays fully
# self-contained. See project_webkit_gtk_headed_recursion.
GTK4_EXCLUDE=""
case "$(basename "$DST")" in
  *gtk*)
    SYS_GTK=$(ls /usr/lib/libgtk-4.so.1 2>/dev/null || true)
    if [ -n "$SYS_GTK" ]; then
      GTK4_EXCLUDE="libgtk-4.so.1 $(ldd "$SYS_GTK" 2>/dev/null | awk '{print $3}' | grep '^/' | xargs -n1 basename | sort -u | tr '\n' ' ')"
      echo "  GTK port: excluding gtk4 closure ($(echo $GTK4_EXCLUDE | wc -w) libs) — consumer apk gtk4.0 supplies them"
    else
      echo "  WARN: GTK port but no system libgtk-4 to compute closure — bundling gtk4 (headed may crash)" >&2
    fi
    ;;
esac

ldd_walk() {
  local target="$1"
  [ -e "$target" ] || return 0
  for so in $(ldd "$target" 2>/dev/null | awk '{print $3}' | grep '^/' || true); do
    base=$(basename "$so")
    case " $EXCLUDE_LIBS " in *" $base "*) continue ;; esac
    # GTK port: skip the gtk4 closure — the consumer's apk gtk4.0 supplies a
    # version-consistent set (see GTK4_EXCLUDE note above).
    case " $GTK4_EXCLUDE " in *" $base "*) continue ;; esac
    [ -f "$so" ] && [ ! -f "$DST/$base" ] && cp -aL "$so" "$DST/" || true
  done
}

# Walk every ELF in $DST (MiniBrowser + aux processes + bundled .so).
walk_pass() {
  for f in "$DST"/*; do
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    ldd_walk "$f"
  done
}
walk_pass
walk_pass
walk_pass

# Flat layout: every ELF gets RPATH=$ORIGIN so it finds bundled peers.
for f in "$DST"/*; do
  [ -L "$f" ] && continue
  [ -f "$f" ] || continue
  patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
done

missing=$(ldd "$DST/MiniBrowser" 2>/dev/null | grep 'not found' || true)
if [ -n "$missing" ]; then
  echo "ERROR: $DST/MiniBrowser still has unresolved deps after bundle:" >&2
  echo "$missing" >&2
  echo "---ldd full output:" >&2
  ldd "$DST/MiniBrowser" 2>&1 | head -40 >&2
  exit 1
fi
echo "===== Self-contained $(basename "$DST"): $(du -sh "$DST" | cut -f1) ====="
