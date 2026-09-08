#!/bin/sh
# Builds zlib-ng in zlib-compat mode and installs it as
# /usr/lib/libz-ng-compat.so.1, an LD_PRELOAD drop-in for Alpine's libz.
#
# Alpine's own zlib-ng package cannot be used for this: it ships only
# libz-ng.so.2, whose 86 exports are all zng_-prefixed and which defines no
# plain `deflate` at all, so preloading it interposes nothing. ZLIB_COMPAT=ON
# is what emits the zlib symbol names.
#
# Run as root (the consumer image calls it under sudo, the conformance runner
# is already root). It installs its own toolchain and removes it again, so the
# caller does not need to.
#
# TWO callers must stay in step, which is why this is a script and not an
# inline RUN: playwright/Dockerfile.alpine builds the image we ship, and
# playwright/alpine-browsers/conformance/build-runner.sh builds the image
# conformance tests. If only the first one gets the preload, conformance is
# green on a browser we do not ship.
set -eu

ZLIB_NG_VERSION="${ZLIB_NG_VERSION:-2.3.3}"
SO=/usr/lib/libz-ng-compat.so.1

apk add --no-cache --virtual .zng-build gcc musl-dev cmake make curl zlib-dev

# --retry-all-errors covers the connection resets this fetch actually sees; an
# unretried failure here surfaces as a build error on whatever RUN line changed
# last, which reads as a code fault rather than a transient.
curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
  -o /tmp/zlib-ng.tar.gz \
  "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${ZLIB_NG_VERSION}.tar.gz"
tar -xzf /tmp/zlib-ng.tar.gz -C /tmp

cmake -S "/tmp/zlib-ng-${ZLIB_NG_VERSION}" -B /tmp/zlib-ng-build \
  -DCMAKE_BUILD_TYPE=Release \
  -DZLIB_COMPAT=ON \
  -DBUILD_SHARED_LIBS=ON \
  -DZLIB_ENABLE_TESTS=OFF \
  -DWITH_GTEST=OFF
cmake --build /tmp/zlib-ng-build -j"$(nproc)"
install -m 0755 "$(find /tmp/zlib-ng-build -maxdepth 1 -name 'libz.so.*' -type f | head -1)" "$SO"

# The smoke has to prove the interposition took effect, or it passes just as
# well without the preload and tells us nothing. zlibVersion() carries a
# "zlib-ng" marker under ZLIB_COMPAT; plain zlib does not.
#
# It deliberately does NOT compare compressed bytes: zlib-ng emits a different
# (2% smaller at level 6) stream than zlib, which is the one behaviour change
# shipping this makes. Correctness here means the round trip and the standard
# CRC-32 vector, not byte equality.
cat > /tmp/zlib-ng-smoke.c <<'EOF'
#include <stdio.h>
#include <string.h>
#include <zlib.h>

int main(void)
{
    unsigned char in[4096], out[8192], back[4096];
    uLongf olen = sizeof out, blen = sizeof back;

    if (!strstr(zlibVersion(), "zlib-ng"))
        return 1;
    if (crc32(0, (const Bytef *)"123456789", 9) != 0xCBF43926UL)
        return 2;

    for (int i = 0; i < 4096; i++)
        in[i] = (unsigned char)(i * 7);
    if (compress(out, &olen, in, sizeof in) != Z_OK)
        return 3;
    if (uncompress(back, &blen, out, olen) != Z_OK)
        return 4;
    if (blen != sizeof in || memcmp(in, back, sizeof in) != 0)
        return 5;

    puts("zlib-ng smoke ok");
    return 0;
}
EOF
gcc -O2 -o /tmp/zlib-ng-smoke /tmp/zlib-ng-smoke.c -lz
LD_PRELOAD="$SO" /tmp/zlib-ng-smoke

rm -rf /tmp/zlib-ng.tar.gz "/tmp/zlib-ng-${ZLIB_NG_VERSION}" /tmp/zlib-ng-build \
       /tmp/zlib-ng-smoke /tmp/zlib-ng-smoke.c
apk del .zng-build
