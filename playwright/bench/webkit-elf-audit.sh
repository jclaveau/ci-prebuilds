#!/bin/sh
# Static audit of the WebKit a given image SHIPS, run inside that image so
# nothing has to be copied out of it.
#
# It answers the questions measurement has already narrowed the `launch` gap
# to. Ours dlopens in ~84 ms against official's ~56 while carrying FEWER
# relocations and a SMALLER .text, so the suspect is the SHAPE of the dynamic
# link rather than its size: which hash table the loader gets to search
# (`.gnu.hash` vs the sysv `.hash` fallback, i.e. bloom filter vs linear
# chain), whether relocations are packed (`.relr.dyn`), and how wide the DSO
# closure is.
#
# It also counts stack-protector canary loads. Alpine's clang forces
# `-fstack-protector-strong` from the DRIVER, which priced at +12.0%
# instructions on a call-dense chromium kernel; that fix was applied to
# chromium only, and nobody has checked whether WebKit pays the same toll.
set -eu

root="${1:?webkit dist dir}"
label="${2:-?}"

# `ls -S` rather than find -printf: busybox find has no -printf.
lib="$(find "$root" -name 'libWPEWebKit*.so.*' -type f -exec ls -S {} + 2>/dev/null | head -1)"
[ -n "$lib" ] || { echo "$label: no libWPEWebKit under $root" >&2; exit 1; }

echo "== $label"
echo "lib:              $lib"
echo "lib-bytes:        $(wc -c < "$lib")"
echo "dt-needed:        $(readelf -d "$lib" | grep -c NEEDED)"
echo "dt-flags:         $(readelf -d "$lib" | grep -E 'FLAGS' | tr -s ' ' | tr '\n' ';')"
echo "has-gnu-hash:     $(readelf -S "$lib" | grep -c '\.gnu\.hash')"
echo "has-sysv-hash:    $(readelf -S "$lib" | grep -cE ' \.hash ')"
echo "has-relr:         $(readelf -S "$lib" | grep -c '\.relr\.dyn')"
echo "dynsyms:          $(readelf --dyn-syms -W "$lib" | grep -c '^ *[0-9]')"
echo "relocs:           $(readelf -r -W "$lib" | grep -c '^[0-9a-f]')"
echo "text-bytes:       $(readelf -S -W "$lib" | awk '$2==".text"{print strtonum("0x" $6)}')"

# One disassembly pass: two greps over a multi-GB stream would double a
# minutes-long step for no extra information.
objdump -d --no-show-raw-insn "$lib" | awk '
  /%fs:0x28/ { canary++ }
  /^ +[0-9a-f]+:/ { insn++ }
  END { printf "canary-loads:     %d\ninsns:            %d\ncanary-per-1k:    %.3f\n",
        canary, insn, (insn ? 1000 * canary / insn : 0) }'

mb="$(find "$root" -name 'MiniBrowser*' -type f | head -1)"
if [ -n "$mb" ]; then
  echo "minibrowser:      $mb"
  echo "ldd-closure:      $(ldd "$mb" 2>/dev/null | grep -c '=>' || echo '?')"
fi
