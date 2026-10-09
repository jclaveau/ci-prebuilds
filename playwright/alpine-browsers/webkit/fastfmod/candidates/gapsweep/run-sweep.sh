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
$cc -O2 -fPIC -shared -o "$out/unified.so" "$here/../unified.c"
set -- "$out/shipped.so" "$out/hybrid.so" "$out/fprem126.so" "$out/unified.so"
# libxul is clang-built, so time the clang codegen of the same source too,
# with the builder's clang (CLANG=clang-23).
clang="${CLANG:-clang}"
if command -v "$clang" >/dev/null; then
  "$clang" -O2 -fPIC -shared -o "$out/unified-clang.so" "$here/../unified.c"
  set -- "$@" "$out/unified-clang.so"
fi
# Firefox's fmod: compiler_builtins' libm fmod, pulled out of the rlib that
# rustc ships (Alpine's `rust` package). The rlib's `fmod` is weak, which ld
# will not extract an archive member for, so a tail-calling shim names the
# strong mangled symbol; its unwind tables want a personality routine that
# fmod never calls.
rlib="$(find / -name 'libcompiler_builtins-*.rlib' 2>/dev/null | head -1)"
if [ -n "$rlib" ]; then
  mangled="$(nm "$rlib" 2>/dev/null |
    awk '$2 == "T" && /libm_math4fmod4fmod$/ {print $3; exit}')"
  cat > "$out/rust-shim.c" <<SHIM
double $mangled(double, double);
double fmod(double x, double y) { return $mangled(x, y); }
void rust_eh_personality(void) {}
SHIM
  $cc -O2 -shared -fPIC -o "$out/rust.so" "$out/rust-shim.c" "$rlib"
  set -- "$@" "$out/rust.so"
fi
$cc -O2 -fno-builtin-fmod -o "$out/gapsweep" "$here/gapsweep.c" -lm -ldl
"$out/gapsweep" "$@"
