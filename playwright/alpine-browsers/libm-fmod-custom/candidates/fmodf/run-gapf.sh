#!/bin/sh
# Per-gap microbench for fmodf: this image's libc against fmodf through
# libm-fmod-custom (via-double), a dedicated integer fmodf, and the shipped
# libm-fmodf-custom.c (integer plus 32-bit and 64-bit single-divide fast
# paths), with gcc and, when present, clang-23. Every result is bit-compared to this libc.
set -eu
here="$(dirname "$0")"
out="${TMPDIR:-/tmp}/gapf"
mkdir -p "$out"
cc="${CC:-gcc}"
$cc -O2 -fPIC -shared -o "$out/fmodf-custom-gcc.so" "$here/fmodf-custom.c"
$cc -O2 -fPIC -shared -o "$out/fmodf-via-double-gcc.so" \
  "$here/fmodf-via-double.c" "$here/../../libm-fmod-custom.c"
$cc -O2 -fPIC -shared -o "$out/fmodf-shipped-gcc.so" "$here/../../libm-fmodf-custom.c"
set -- "$out/fmodf-custom-gcc.so" "$out/fmodf-via-double-gcc.so" "$out/fmodf-shipped-gcc.so"
if command -v clang-23 >/dev/null; then
  clang-23 -O2 -fPIC -shared -o "$out/fmodf-custom-clang23.so" "$here/fmodf-custom.c"
  clang-23 -O2 -fPIC -shared -o "$out/fmodf-shipped-clang23.so" "$here/../../libm-fmodf-custom.c"
  set -- "$@" "$out/fmodf-custom-clang23.so" "$out/fmodf-shipped-clang23.so"
fi
$cc -O2 -fno-builtin -o "$out/gapf" "$here/gapf.c" -lm -ldl
"$out/gapf" "$@"
