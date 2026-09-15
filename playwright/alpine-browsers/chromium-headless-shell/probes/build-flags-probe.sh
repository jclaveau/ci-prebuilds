#!/bin/bash
# DIAG BRANCH ONLY — re-links headless_shell in a round image with a symbol
# ordering file built from the box's perf profile (issue #249 item 1: our hot
# Blink code sits in two bands of .text, official's in one). Dispatched via
# chromium-build-flags-probe.yml with script_ref=diag/chromium-symtab-dump.
# Produces /out/headless_shell_ord.gz (stripped) + lld's printed symbol orders.
set -uo pipefail
OUT="${1:?outdir}"
mkdir -p "$OUT"
WORK=/work
set -a; . "$WORK/versions.env"; . "$WORK/derived.env"; set +a
CHS_VER="${CHROMIUM_HEADLESS_SHELL_VERSION:?}"
cd "$WORK/chromium-src/chromium-$CHS_VER/out/headless" || exit 2
ORDER=/probes/chs.orderfile
[[ -f "$ORDER" ]] || { echo "ERROR: $ORDER missing" >&2; exit 2; }
LLVM=$(ls -d /usr/lib/llvm2*/bin | sort | tail -1)
LINK=$(ninja -t commands headless_shell 2>/dev/null | tail -1)
[[ "$LINK" == *gcc_link_wrapper.py* ]] || { echo "ERROR: unexpected link line: ${LINK:0:200}" >&2; exit 2; }
echo "$LINK" > "$OUT/link-cmd.txt"

relink() {  # relink <suffix> <extra ldflags...>
  local sfx="$1"; shift
  local cmd="${LINK//\"\.\/headless_shell\"/\"./headless_shell_$sfx\"}"
  cmd="${cmd//--output=\"\.\/headless_shell_$sfx\"/--output=\"./headless_shell_$sfx\"}"
  cmd="$cmd $*"
  echo "### link $sfx: $(date -u +%H:%M:%S)"
  local t0=$SECONDS
  eval "$cmd" > "$OUT/link-$sfx.log" 2>&1; local rc=$?
  echo "### link $sfx rc=$rc in $((SECONDS-t0))s"; tail -5 "$OUT/link-$sfx.log"
  [[ $rc -eq 0 ]] || return $rc
  ls -la "headless_shell_$sfx"
  "$LLVM/llvm-nm" -n --defined-only -S "headless_shell_$sfx" | gzip -6 > "$OUT/symtab-$sfx.nm.gz"
  "$LLVM/llvm-readelf" -SW "headless_shell_$sfx" | grep -E "\] \.text" > "$OUT/text-$sfx.txt"
  cp "headless_shell_$sfx" "/tmp/hs_$sfx" && "$LLVM/llvm-strip" --strip-all "/tmp/hs_$sfx" && gzip -6 -c "/tmp/hs_$sfx" > "$OUT/headless_shell_$sfx.gz" && rm -f "/tmp/hs_$sfx"
  ls -la "$OUT/headless_shell_$sfx.gz"
}

relink ord "-Wl,--symbol-ordering-file=$ORDER" "-Wl,--no-warn-symbol-ordering" "-Wl,--print-symbol-order=$OUT/order-ord.txt" || exit 3
relink ctl "-Wl,--print-symbol-order=$OUT/order-ctl.txt" || exit 3
gzip -6 "$OUT/order-ord.txt" "$OUT/order-ctl.txt" 2>/dev/null
echo "### DONE"
