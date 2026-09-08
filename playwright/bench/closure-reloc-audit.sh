#!/bin/sh
# Totals the dynamic-linking work a WebKit launch actually pays for, across
# the WHOLE closure rather than libWPEWebKit alone.
#
# Why: `MiniBrowser --version` loads the closure, prints a string and exits,
# and it runs 69 ms on our image against 41 ms on Playwright's. In that
# profile the browser library never appears — the dynamic linker is 14% of all
# samples on our side and 12% on theirs, which per iteration is musl doing
# about twice the work. musl has no lazy binding, so it resolves every symbol
# reference in every object at load; glibc resolves only what gets called.
#
# That makes the question quantitative: does our closure simply REFER to more
# symbols, or does musl cost more per reference? These are the two numbers
# that separate those, so both images print them the same way.
set -eu

bin=$(ls -d /ms-playwright/webkit-*/minibrowser-wpe 2>/dev/null | head -1)/MiniBrowser
[ -f "$bin" ] || { echo "no MiniBrowser found" >&2; exit 1; }

if command -v readelf >/dev/null 2>&1; then
  :
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache binutils >/dev/null 2>&1
else
  apt-get update >/dev/null 2>&1
  apt-get install -y binutils >/dev/null 2>&1
fi

list=$(mktemp)
{ echo "$bin"; ldd "$bin" 2>/dev/null | sed -n 's/.*=> \(\/[^ ]*\).*/\1/p'; } \
  | sort -u > "$list"

echo "closure-dsos $(wc -l < "$list")"

awk_totals='
  /JUMP_SLOT|GLOB_DAT/ { sym += $1 }
  /RELATIVE/           { rel += $1 }
  END { printf "%d %d\n", sym + 0, rel + 0 }
'

sym_total=0
rel_total=0
und_total=0
while read -r f; do
  counts=$(readelf -r -W "$f" 2>/dev/null \
    | awk 'NF > 2 { print $3 }' | sort | uniq -c | awk "$awk_totals")
  sym_total=$((sym_total + ${counts% *}))
  rel_total=$((rel_total + ${counts#* }))
  und_total=$((und_total + $(readelf --dyn-syms -W "$f" 2>/dev/null \
    | awk '$7 == "UND"' | wc -l)))
done < "$list"
rm -f "$list"

echo "closure-symbol-relocs $sym_total"
echo "closure-relative-relocs $rel_total"
echo "closure-undefined-syms $und_total"
