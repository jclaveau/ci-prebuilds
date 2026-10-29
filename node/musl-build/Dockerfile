# syntax=docker/dockerfile:1
#
# Stage B of #351: node built here, for musl, with clang23 + ThinLTO + PGO.
# Build context is node/ (the PGO training reruns bench/node-perf-kernel.cjs).
#
#   pgo-profile    instrumented build, trained, merged: /pgo/node-<sha>.profdata
#   node-plain     the profile-guided build, musl's malloc: /node = a /usr/local tree
#   node-mimalloc  the same objects linked with mimalloc-insecure statically
#
# The two node trees share every object: only the final links differ, and the
# ThinLTO cache makes the second one cheap. A consumer replaces its node with
# `COPY --from=ghcr.io/jclaveau/node-musl:<tag> /node/ /usr/local/`.

ARG NODE_VERSION=24.22.1
# An image holding /pgo/node-<sha>.profdata (this file's pgo-profile target),
# so CI can run the instrumented build and the final one as separate jobs. Unset
# = trained inline, in the same build.
ARG PGO_PROFILE_IMAGE

# Alpine edge, as the browsers: clang23 and its compiler-rt (the profile
# runtime) exist only there, 3.24 stops at clang22. The edge-built node runs on
# the 3.24 consumer because both ship musl 1.2.6 and gcc 15.2's libstdc++; the
# consumer smoke runs it there before anything else does.
FROM alpine:edge AS toolchain
ARG NODE_VERSION
RUN apk add --no-cache \
        bash clang23 compiler-rt curl g++ linux-headers lld23 llvm23 make \
        mimalloc2-dev python3 tar xz
# Alpine edge ships sccache 0.15, whose GHA backend writes the deprecated path
# and goes read-only (project_sccache_ghac_readonly_v18); 0.16 works.
RUN curl -fsSL "https://github.com/mozilla/sccache/releases/download/v0.16.0/sccache-v0.16.0-x86_64-unknown-linux-musl.tar.gz" \
      | tar -xz -C /tmp \
 && install -m755 /tmp/sccache-v0.16.0-x86_64-unknown-linux-musl/sccache /usr/local/bin/sccache \
 && rm -rf /tmp/sccache-v0.16.0-x86_64-unknown-linux-musl \
 && sccache --version
COPY musl-build/node-source-sha256.txt /work/
RUN set -eu \
    && pinned_sha=$(awk -v v="${NODE_VERSION}" '$1 == v { print $2 }' /work/node-source-sha256.txt) \
    && if [ -z "$pinned_sha" ]; then \
         echo "node ${NODE_VERSION} has no sha256 in node/musl-build/node-source-sha256.txt" >&2; \
         exit 1; \
       fi \
    && curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}.tar.xz" \
    && echo "${pinned_sha}  /tmp/node.tar.xz" | sha256sum -c - \
    && mkdir -p /work/node-src \
    && tar -xJf /tmp/node.tar.xz -C /work/node-src --strip-components=1 \
    && rm /tmp/node.tar.xz
COPY musl-build/build-node.sh /work/

# ---- PGO: instrument, train, merge ------------------------------------------
FROM toolchain AS pgo-generate
RUN --mount=type=cache,target=/root/.cache/sccache,id=node-musl-sccache,sharing=locked \
    --mount=type=secret,id=actions_runtime_token \
    --mount=type=secret,id=actions_results_url \
    bash /work/build-node.sh generate /opt/node-gen

FROM toolchain AS pgo-train
COPY --from=pgo-generate /opt/node-gen/usr/local /usr/local
COPY bench/node-perf-kernel.cjs musl-build/pgo-train.sh /train/
COPY musl-build/pgo-fixture /train/fixture
RUN sh /train/pgo-train.sh

FROM scratch AS pgo-profile
COPY --from=pgo-train /pgo /pgo

FROM ${PGO_PROFILE_IMAGE:-pgo-profile} AS pgo-profile-in

# ---- the profile-guided build -----------------------------------------------
FROM toolchain AS pgo-use
COPY --from=pgo-profile-in /pgo /pgo
RUN --mount=type=cache,target=/root/.cache/sccache,id=node-musl-sccache,sharing=locked \
    --mount=type=secret,id=actions_runtime_token \
    --mount=type=secret,id=actions_results_url \
    bash /work/build-node.sh use /opt/node-plain /opt/node-mimalloc

FROM scratch AS node-plain
COPY --from=pgo-use /opt/node-plain/usr/local /node

FROM scratch AS node-mimalloc
COPY --from=pgo-use /opt/node-mimalloc/usr/local /node
