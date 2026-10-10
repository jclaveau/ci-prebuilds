#!/bin/sh
# Per-gap microbench for fmodf: this image's libc against fmodf through
# libm-fmod-custom (via-double), the divl candidate (fmodf-divl.c), and the
# shipped libm-fmodf-custom.c built as it ships
# (-mbranches-within-32B-boundaries) and without that flag, with gcc
# and, when present, clang-23. Every result is bit-compared to this libc.
set -eu
here="$(dirname "$0")"
out="${TMPDIR:-/tmp}/gapf"
mkdir -p "$out"
cc="${CC:-gcc}"
pad=-mbranches-within-32B-boundaries
# -Bsymbolic binds via-double's fmod call to the libm-fmod-custom copy linked
# beside it; without it the call goes through the PLT to this libc's fmod.
$cc -O2 -fPIC -shared -Wl,-Bsymbolic -o "$out/fmodf-via-double-gcc.so" \
  "$here/fmodf-via-double.c" "$here/../../libm-fmod-custom.c"
$cc -O2 -fPIC -shared -o "$out/fmodf-divl-gcc.so" "$here/fmodf-divl.c"
$cc -O2 -fPIC -shared -o "$out/fmodf-unpadded-gcc.so" "$here/../../libm-fmodf-custom.c"
$cc -O2 -fPIC -shared -Wa,$pad -o "$out/fmodf-shipped-gcc.so" "$here/../../libm-fmodf-custom.c"
set -- "$out/fmodf-via-double-gcc.so" "$out/fmodf-divl-gcc.so" \
  "$out/fmodf-unpadded-gcc.so" "$out/fmodf-shipped-gcc.so"
if command -v clang-23 >/dev/null; then
  clang-23 -O2 -fPIC -shared -o "$out/fmodf-divl-clang23.so" "$here/fmodf-divl.c"
  clang-23 -O2 -fPIC -shared $pad -o "$out/fmodf-shipped-clang23.so" "$here/../../libm-fmodf-custom.c"
  set -- "$@" "$out/fmodf-divl-clang23.so" "$out/fmodf-shipped-clang23.so"
fi
$cc -O2 -fno-builtin -o "$out/gapf" "$here/gapf.c" -lm -ldl
"$out/gapf" "$@"
