#!/bin/bash
# Builds node's bundled zlib (deps/zlib of NODE_VERSION) into the gzip
# harness once per arm, with clang23 at node's -O3, statically linked.
# Run in alpine:edge, as node's builder. Writes /out/arms/<arm>/harness and
# /out/heads.txt, the 32- and 64-byte offsets of deflate_slow's two hot loops.
#
# Arms (all clang23 unless named):
#   pad0 pad16 pad32 pad48  -U_FORTIFY_SOURCE -falign-loops=16 (the candidate
#                           node's flags), with N bytes of .text linked ahead
#                           of zlib, so only where the loops land varies.
#   align32                 -U_FORTIFY_SOURCE -falign-loops=32.
#   fortify                 Alpine clang's default _FORTIFY_SOURCE=2 (the
#                           shipped Stage B's flags), -falign-loops=16.
#   builtin                 fortify, zlib's 4 fixed-size loads via __builtin_memcpy.
#   gcc                     fortify, zlib compiled with Alpine gcc.
#   headers                 fortify, fortify-headers' memcpy overlap trap removed.
set -euo pipefail
: "${NODE_VERSION:?}"
# gcc: crtbeginT.o and libgcc_eh for the static link the ubuntu runners need.
apk add --no-cache bash binutils clang23 curl gcc lld23 llvm23 musl-dev python3 tar xz >/dev/null
clang-23 --version | head -1

mkdir -p /work /out/arms
cd /work
curl -fsSLo node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}.tar.xz"
curl -fsSLo SHASUMS256.txt "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
tarball_sha=$(awk -v name="node-v${NODE_VERSION}.tar.xz" '$2 == name { print $1 }' SHASUMS256.txt)
[ -n "$tarball_sha" ] || { echo "no node-v${NODE_VERSION}.tar.xz in SHASUMS256.txt" >&2; exit 1; }
echo "$tarball_sha  node.tar.xz" | sha256sum -c -
tar -xJf node.tar.xz --strip-components=2 "node-v${NODE_VERSION}/deps/zlib"
zlib_dir=/work/zlib
[ -f "$zlib_dir/deflate.c" ] || { echo "no deps/zlib/deflate.c in node-v${NODE_VERSION}" >&2; exit 1; }

# zlib.gyp on x64 Linux: the "zlib" target plus its zlib_adler32_simd and
# zlib_data_chunk_simd dependencies, each with the defines gyp gives it.
# node leaves the crc32 SIMD target commented out.
zlib_sources="adler32.c compress.c cpu_features.c crc32.c deflate.c gzclose.c gzlib.c
  gzread.c gzwrite.c infback.c inffast.c inftrees.c trees.c uncompr.c zutil.c"
chunk_sources="contrib/optimizations/inffast_chunk.c contrib/optimizations/inflate.c"
simd_defines="-DADLER32_SIMD_SSSE3 -DX86_NOT_WINDOWS -DINFLATE_CHUNK_SIMD_SSE2 -DINFLATE_CHUNK_READ_64LE"
zlib_flags="-O3 $simd_defines -DDEFLATE_SLIDE_HASH_SSE2 -DHAVE_HIDDEN -DZLIB_IMPLEMENTATION -Wno-implicit-fallthrough"
chunk_flags="-O3 -DINFLATE_CHUNK_SIMD_SSE2 -DINFLATE_CHUNK_READ_64LE"
adler_flags="-O3 -DADLER32_SIMD_SSSE3 -DX86_NOT_WINDOWS -mssse3"

compile_set() {
  local set_flags=$1 source_name object_name
  shift
  for source_name in "$@"; do
    object_name=$arm_dir/obj/$(echo "${source_name%.c}" | tr / _).o
    $arm_cc $set_flags -I"$arm_zlib_dir" -c "$arm_zlib_dir/$source_name" -o "$object_name"
    object_list="$object_list $object_name"
  done
}

# build_arm <arm> <pad bytes> <flags> [compiler] [zlib source dir]
build_arm() {
  local arm_name=$1 pad_bytes=$2 arm_flags=$3
  arm_cc=${4:-clang-23}
  arm_zlib_dir=${5:-$zlib_dir}
  arm_dir=/out/arms/$arm_name
  object_list=""
  mkdir -p "$arm_dir/obj"
  printf '.text\n.globl text_pad\ntext_pad:\n.skip %d, 0x90\n' "$pad_bytes" > "$arm_dir/obj/pad.s"
  clang-23 -c "$arm_dir/obj/pad.s" -o "$arm_dir/obj/pad.o"
  compile_set "$zlib_flags $arm_flags" $zlib_sources
  compile_set "$chunk_flags $arm_flags" $chunk_sources
  compile_set "$adler_flags $arm_flags" adler32_simd.c
  clang-23 $zlib_flags -I"$arm_zlib_dir" $arm_flags -c /bench/harness.c -o "$arm_dir/obj/harness.o"
  # pad.o first, so the skip shifts every zlib function after it.
  clang-23 -static -fuse-ld=lld -o "$arm_dir/harness" "$arm_dir/obj/pad.o" $object_list "$arm_dir/obj/harness.o" -lm
}

no_fortify="-U_FORTIFY_SOURCE -falign-loops=16"
for pad_bytes in 0 16 32 48; do build_arm "pad$pad_bytes" "$pad_bytes" "$no_fortify"; done
build_arm align32 0 "-U_FORTIFY_SOURCE -falign-loops=32"
build_arm fortify 0 "-falign-loops=16"

# The ways to keep _FORTIFY_SOURCE=2 without the overlap trap in deflate's
# hot loops. pad0 already stands for fortify off in zlib alone.
# builtin: zlib's fixed-size loads into locals (insert_string.h, compare256.h)
# call __builtin_memcpy, which fortify-headers' inline memcpy does not wrap.
cp -r "$zlib_dir" /work/zlib-builtin
sed -i 's/zmemcpy(&value, /__builtin_memcpy(\&value, /' /work/zlib-builtin/contrib/optimizations/insert_string.h
sed -i 's/\bmemcpy(&/__builtin_memcpy(\&/' /work/zlib-builtin/compare256.h
builtin_sites=$(grep -c '__builtin_memcpy(&' /work/zlib-builtin/contrib/optimizations/insert_string.h /work/zlib-builtin/compare256.h | awk -F: '{ total += $2 } END { print total }')
[ "$builtin_sites" -eq 4 ] || { echo "expected 4 __builtin_memcpy sites in zlib, patched $builtin_sites" >&2; exit 1; }
build_arm builtin 0 "-falign-loops=16" clang-23 /work/zlib-builtin
# gcc: Alpine gcc 15 also predefines _FORTIFY_SOURCE=2, and folds the overlap
# compare against a local away by itself.
build_arm gcc 0 "-falign-loops=16" gcc
# headers: fortify-headers' memcpy without the overlap trap, keeping its size
# trap, as glibc's __memcpy_chk does. Edits this container's header, so last.
python3 - <<'PY'
import pathlib
header = pathlib.Path('/usr/include/fortify/string.h')
header_text = header.read_text()
overlap_trap = """	if ((__d < __s && __d + __n > __s) ||
	    (__s < __d && __s + __n > __d))
		__builtin_trap();
	if (__n > __bd || __n > __bs)"""
if header_text.count(overlap_trap) != 1:
    raise SystemExit('fortify-headers memcpy overlap trap not found once in /usr/include/fortify/string.h')
header.write_text(header_text.replace(overlap_trap, "	if (__n > __bd || __n > __bs)"))
PY
build_arm headers 0 "-falign-loops=16"

: > /out/heads.txt
for arm_dir in /out/arms/*/; do
  python3 /bench/loop-heads.py "${arm_dir}harness" "$(basename "$arm_dir")" | tee -a /out/heads.txt
done
