#!/bin/bash
# Builds node's bundled zlib (deps/zlib of NODE_VERSION) into the gzip
# harness once per arm, with clang23 at node's -O3, statically linked.
# Run in alpine:edge, as node's builder. Writes /out/arms/<arm>/harness and
# /out/heads.txt, the 32- and 64-byte offsets of deflate_slow's two hot loops.
#
# Arms:
#   pad0 pad16 pad32 pad48  -U_FORTIFY_SOURCE -falign-loops=16 (the candidate
#                           node's flags), with N bytes of .text linked ahead
#                           of zlib, so only where the loops land varies.
#   align32                 -U_FORTIFY_SOURCE -falign-loops=32.
#   fortify                 Alpine clang's default _FORTIFY_SOURCE=2 (the
#                           shipped Stage B's flags), -falign-loops=16.
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
zlib_flags="-O3 $simd_defines -DDEFLATE_SLIDE_HASH_SSE2 -DHAVE_HIDDEN -DZLIB_IMPLEMENTATION -Wno-implicit-fallthrough -I$zlib_dir"
chunk_flags="-O3 -DINFLATE_CHUNK_SIMD_SSE2 -DINFLATE_CHUNK_READ_64LE -I$zlib_dir"
adler_flags="-O3 -DADLER32_SIMD_SSSE3 -DX86_NOT_WINDOWS -mssse3 -I$zlib_dir"

compile_set() {
  local set_flags=$1 source_name object_name
  shift
  for source_name in "$@"; do
    object_name=$arm_dir/obj/$(echo "${source_name%.c}" | tr / _).o
    clang-23 $set_flags -c "$zlib_dir/$source_name" -o "$object_name"
    object_list="$object_list $object_name"
  done
}

build_arm() {
  local arm_name=$1 pad_bytes=$2 arm_flags=$3
  arm_dir=/out/arms/$arm_name
  object_list=""
  mkdir -p "$arm_dir/obj"
  printf '.text\n.globl text_pad\ntext_pad:\n.skip %d, 0x90\n' "$pad_bytes" > "$arm_dir/obj/pad.s"
  clang-23 -c "$arm_dir/obj/pad.s" -o "$arm_dir/obj/pad.o"
  compile_set "$zlib_flags $arm_flags" $zlib_sources
  compile_set "$chunk_flags $arm_flags" $chunk_sources
  compile_set "$adler_flags $arm_flags" adler32_simd.c
  clang-23 $zlib_flags $arm_flags -c /bench/harness.c -o "$arm_dir/obj/harness.o"
  # pad.o first, so the skip shifts every zlib function after it.
  clang-23 -static -fuse-ld=lld -o "$arm_dir/harness" "$arm_dir/obj/pad.o" $object_list "$arm_dir/obj/harness.o" -lm
}

no_fortify="-U_FORTIFY_SOURCE -falign-loops=16"
for pad_bytes in 0 16 32 48; do build_arm "pad$pad_bytes" "$pad_bytes" "$no_fortify"; done
build_arm align32 0 "-U_FORTIFY_SOURCE -falign-loops=32"
build_arm fortify 0 "-falign-loops=16"

: > /out/heads.txt
for arm_dir in /out/arms/*/; do
  python3 /bench/loop-heads.py "${arm_dir}harness" "$(basename "$arm_dir")" | tee -a /out/heads.txt
done
