#!/bin/bash
# DIAG BRANCH ONLY — replaces the flags probe with a symbol-table dump of the
# unstripped chrome-headless-shell in a round image, for the hot-page census
# (issue #249 item 1: which functions sit in our hot text tail). Dispatched via
# chromium-build-flags-probe.yml with script_ref=diag/chromium-symtab-dump.
set -uo pipefail
OUT="${1:?outdir}"
mkdir -p "$OUT"
WORK=/work
set -a; . "$WORK/versions.env"; . "$WORK/derived.env"; set +a
CHS_VER="${CHROMIUM_HEADLESS_SHELL_VERSION:?}"
cd "$WORK/chromium-src/chromium-$CHS_VER" || exit 2
B=out/headless/chrome-headless-shell
[[ -f "$B" ]] || { echo "ERROR: $B missing" >&2; ls out/headless | head >&2; exit 2; }
LLVM=$(ls -d /usr/lib/llvm2*/bin 2>/dev/null | sort | tail -1)
NM="$LLVM/llvm-nm"; RE="$LLVM/llvm-readelf"
[[ -x "$NM" ]] || NM=nm; [[ -x "$RE" ]] || RE=readelf
{
  echo "binary: $B"; ls -la "$B"; file "$B" 2>/dev/null
  "$RE" -SW "$B" | grep -E "\] \.(text|rodata|symtab|strtab)"
  "$RE" -lW "$B" | grep -E "LOAD|Align"
  ls -d /usr/lib/llvm2* ; "$LLVM/ld.lld" --version 2>/dev/null || ld.lld --version
} > "$OUT/binary-info.txt" 2>&1
cat "$OUT/binary-info.txt"
# address size type name, sorted by address; ~1M lines, gzip
"$NM" -n --defined-only -S "$B" 2>/dev/null | gzip -6 > "$OUT/symtab.nm.gz"
ls -la "$OUT/symtab.nm.gz"; zcat "$OUT/symtab.nm.gz" | wc -l
# the link line, to see the ldflags actually used (call-graph sort, prefixes)
ninja -C out/headless -t commands chrome-headless-shell 2>/dev/null | tail -1 > "$OUT/link-cmd.txt"
rsp=$(grep -o '@[^ ]*\.rsp' "$OUT/link-cmd.txt" | head -1 | tr -d @)
[[ -n "$rsp" && -f "out/headless/$rsp" ]] && { tr ' ' '\n' < "out/headless/$rsp" | grep -E "^-Wl|^-fuse-ld|lto|^-m|^-O|-z" | sort -u > "$OUT/link-flags.txt"; }
grep -oE "\-Wl,[^ ]+|-fuse-ld=[^ ]+|-flto[^ ]*|-O[0-9s]" "$OUT/link-cmd.txt" | sort -u >> "$OUT/link-flags.txt"
cat "$OUT/link-flags.txt" | head -60
# one summary line per prefixed section family, from an object that still is ELF (host tools are)
"$RE" -SW out/headless/obj/headless/headless_shell/headless_shell.o 2>/dev/null | grep -cE "\.text\.(hot|unlikely|startup|split)" | sed 's/^/prefixed .text sections in headless_shell.o: /'
echo "### DONE"
