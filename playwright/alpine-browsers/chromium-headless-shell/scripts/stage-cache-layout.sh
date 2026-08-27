#!/usr/bin/env bash
# Rename the chromium-dist tree into the directory shape PW SDK expects for
# auto-discovery via PLAYWRIGHT_BROWSERS_PATH.
#
# Source layout (from apply-and-build.sh):
#   /work/chromium-dist/
#     chrome-headless-shell  ← binary (renamed from headless_shell)
#     icudtl.dat, *.bin, *.pak, locales/, …
#
# Target layout (what PW SDK reads at launch time):
#   ${PLAYWRIGHT_BROWSERS_PATH}/chromium_headless_shell-${CHS_REV}/
#     chrome-headless-shell-linux64/
#       chrome-headless-shell
#       icudtl.dat, *.bin, *.pak, locales/, …
#     INSTALLATION_COMPLETE        ← empty marker; PW checks for this
#
# This script outputs the inner `chrome-headless-shell-linux64/` tree under
# /work/chromium-shell-linux64/ — the Dockerfile's artifact stage COPYs that
# into the scratch image at /chrome-headless-shell-linux64. The consumer
# Dockerfile then re-layouts into the registry directory + marker.

set -euo pipefail

WORK="${1:?usage: stage-cache-layout.sh <work_dir>}"
# VARIANT (headless|headed) selects the PW-discovery layout dir + binary name.
. "$WORK/chromium-headless-shell/scripts/variant-config.sh"
DIST="$WORK/chromium-dist"
OUT="$WORK/$VARIANT_LAYOUT"

[[ -d "$DIST" ]] || { echo "missing $DIST (apply-and-build.sh ran?)" >&2; exit 1; }

# headless: GN outputs `headless_shell`; PW expects `chrome-headless-shell`.
# headed: GN outputs `chrome`; PW expects `chrome` (no rename → this is a no-op
# since $VARIANT_DIST_BIN == $VARIANT_BIN).
if [[ -f "$DIST/$VARIANT_BIN" && ! -f "$DIST/$VARIANT_DIST_BIN" ]]; then
  mv "$DIST/$VARIANT_BIN" "$DIST/$VARIANT_DIST_BIN"
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$DIST/." "$OUT/"

# libVkLayer_khronos_validation.so is a Vulkan debug layer: only dlopen'd when
# the loader is explicitly told to enable validation (VK_INSTANCE_LAYERS /
# VK_LOADER_LAYERS_ENABLE), which neither PW nor our conformance suite does —
# the binary doesn't NEED it. ~22M of dead weight per artifact.
rm -f "$OUT/libVkLayer_khronos_validation.so"

# Strip symbol tables from the shipped ELF binaries, matching PW's official
# prebuilt (which ships stripped). GN `symbol_level = 0` already omits DWARF
# debug info, but the linker still emits `.symtab`/`.strtab`; strip removes them
# with no runtime effect — the dynamic symbol table (`.dynsym`) that loading
# needs is left untouched by `--strip-all`. `binutils` (strip) + `file` come
# from the builder base (Dockerfile setup). Non-ELF files (.pak/.dat/.bin,
# locales) are skipped via the `file` type check.
# Did the stack-protector parity flag actually reach the compiler? A build that
# silently ignored it is a null arm that would otherwise ship looking like a
# result — and the answer is only visible in the linked binary, which exists
# here and nowhere earlier. Reported, not enforced: failing a 25-30 h chain at
# the last step over a diagnostic would cost more than reading the number.
# Reference points: official 33 166 canary loads, our strong-by-default build
# 358 107.
if command -v objdump >/dev/null 2>&1; then
  canaries=$(objdump -d "$OUT/$VARIANT_DIST_BIN" 2>/dev/null \
    | grep -c 'fs:0x28' || true)
  echo "Stack-protector canary loads in $VARIANT_DIST_BIN: ${canaries}" \
       "(official 33166, alpine-strong 358107)"
fi

before=$(du -sh "$OUT" | cut -f1)
find "$OUT" -type f -print0 | while IFS= read -r -d '' f; do
  case "$(file -b "$f" 2>/dev/null)" in
    *ELF*) strip --strip-all "$f" 2>/dev/null || true ;;
  esac
done
echo "Stripped ELF binaries in $OUT: ${before} -> $(du -sh "$OUT" | cut -f1)"

echo "Staged cache layout at $OUT:"
ls -lh "$OUT" | head -20
