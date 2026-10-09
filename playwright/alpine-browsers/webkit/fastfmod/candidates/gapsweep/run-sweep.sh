#!/bin/sh
# Per-gap ns/call of the shipped shim and the hybrid candidates against this
# image's libc, every result bit-compared to libc. Exponent gap is what
# separates them: fprem wins narrow, the wide reduction wins past ~126 bits.
set -eu
here="$(dirname "$0")"
out="${TMPDIR:-/tmp}/gapsweep"
mkdir -p "$out"
cc="${CC:-gcc}"
$cc -O2 -fPIC -shared -o "$out/shipped.so" "$here/../../fastfmod.c"
$cc -O2 -fPIC -shared -o "$out/hybrid.so" "$here/../hybrid.c"
$cc -O2 -fPIC -shared -o "$out/fprem126.so" "$here/../fprem126.c"
$cc -O2 -fno-builtin-fmod -o "$out/gapsweep" "$here/gapsweep.c" -lm -ldl
"$out/gapsweep" "$out/shipped.so" "$out/hybrid.so" "$out/fprem126.so"
