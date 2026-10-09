#!/bin/sh
# Per-gap microbench for fmodf: this image's libc against fmodf through
# libm-fmod-custom (via-double) and a dedicated integer fmodf, with gcc and,
# when present, clang-23. Every result is bit-compared to this libc.
set -eu
here="$(dirname "$0")"
out="${TMPDIR:-/tmp}/gapf"
mkdir -p "$out"
cc="${CC:-gcc}"
$cc -O2 -fPIC -shared -o "$out/fmodf-custom-gcc.so" "$here/fmodf-custom.c"
$cc -O2 -fPIC -shared -o "$out/fmodf-via-double-gcc.so" \
  "$here/fmodf-via-double.c" "$here/../../libm-fmod-custom.c"
set -- "$out/fmodf-custom-gcc.so" "$out/fmodf-via-double-gcc.so"
if command -v clang-23 >/dev/null; then
  clang-23 -O2 -fPIC -shared -o "$out/fmodf-custom-clang23.so" "$here/fmodf-custom.c"
  set -- "$@" "$out/fmodf-custom-clang23.so"
fi
$cc -O2 -fno-builtin -o "$out/gapf" "$here/gapf.c" -lm -ldl
"$out/gapf" "$@"
