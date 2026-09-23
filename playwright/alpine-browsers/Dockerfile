# syntax=docker/dockerfile:1
#
# Build patched Playwright browsers on musl. v1 ships Firefox only (WebKit/WPE
# on musl is materially harder and deferred — see plan + README).
#
# Strategy: take Alpine community/firefox's APKBUILD recipe (which already
# builds Firefox 151.x on musl), apply Playwright's bootstrap.diff + Juggler
# tree on top, build, copy the dist out into a `FROM scratch` artifact image.
#
# The artifact image has no shell, no libs of its own — only the `firefox/`
# tree. Consumers `COPY --from=jclaveau/playwright-alpine-browsers:<tag>
# /firefox /opt/playwright/firefox` and `apk add` the runtime libs themselves.

# Builder uses Alpine edge because aports HEAD's community/firefox APKBUILD
# tracks edge — Alpine 3.21 stable doesn't ship a new enough clang.
# The artifact image (FROM scratch) inherits no Alpine version; the runtime
# Alpine version is the consumer's choice.
ARG ALPINE_VERSION=edge
# PGO profile input for the `use` stage: an image holding /pgo/merged.profdata
# (+ en-US.log), published by the workflow's build-firefox-pgo-profile job from
# this same Dockerfile's `pgo-profile` target. Unset = an empty /pgo, which the
# script only reads under PGO_STAGE=use.
ARG PGO_PROFILE_IMAGE

# ---- Firefox builder ---------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS pgo-profile-none
RUN mkdir /pgo

FROM ${PGO_PROFILE_IMAGE:-pgo-profile-none} AS pgo-profile-in

FROM alpine:${ALPINE_VERSION} AS firefox-builder

# Bash + tooling for our scripts; the rest matches aports' community/firefox
# `makedepends`. clang/lld/llvm track edge's DEFAULT llvm, not aports'
# `_llvmver`: compiler-rt and wasi-sdk exist only for the default one, and a
# build that links a profile runtime or the wasm sandbox needs them. The
# version actually used is picked by apply-and-build.sh, which prefers the pin
# and falls forward to whichever llvm owns the runtimes.
RUN apk add --no-cache \
        bash curl git patch patchutils tar xz gzip jq gettext-envsubst make sccache \
        alsa-lib-dev automake binutils bsd-compat-headers cargo cbindgen \
        clang23 clang23-libclang clang23-dev compiler-rt \
        dbus dbus-dev gettext gtk+3.0-dev hunspell-dev icu-dev icu-data-full \
        libevent-dev libffi-dev libjpeg-turbo-dev libnotify-dev libogg-dev \
        libtheora-dev libtool libvorbis-dev libvpx-dev libwebp-dev \
        libxcomposite-dev libxt-dev lld23 llvm23-dev m4 mesa-dev \
        mesa-dri-gallium mimalloc2-insecure nasm nodejs nspr-dev nss-dev \
        patchelf pciutils pipewire-dev pulseaudio-dev py3-mozshellutil \
        python3 perl scudo-malloc sed wasi-sdk wireless-tools-dev \
        xvfb-run zip

WORKDIR /work

# Pins (PW_VERSION + ALPINE_APORTS_REF). The version.env is sourced for env, so
# we keep it shell-syntax. Layered before the script COPY so changing scripts
# alone doesn't bust the (small) deps cache here.
COPY versions.env /work/versions.env

# Scripts + overlay drive the build; smoke/ is NOT copied here — it's
# consumed by the producer workflow's Tier-2 step via bind-mount from the
# checked-out repo. Excluding smoke/ from this layer means edits to smoke
# scripts don't invalidate the heavy RUN below.
COPY firefox/scripts /work/firefox/scripts
COPY firefox/mozconfig.overlay /work/firefox/mozconfig.overlay
COPY firefox/pgo-corpus /work/firefox/pgo-corpus

# Fetch aports community/firefox + PW's browser_patches/firefox. Both are
# version-pinned via versions.env so the layer cache invalidates iff the pins
# move (or scripts change above).
RUN set -a && . /work/versions.env && set +a \
    && bash /work/firefox/scripts/fetch-aports.sh /work/aports \
    && bash /work/firefox/scripts/fetch-pw-patches.sh /work/pw-firefox

# The heavyweight step: clone Firefox source, apply patches, run ./mach build.
#
# Cache mounts persist across `docker build` invocations and across CI runs
# (via the GHA cache backend). When a script change invalidates this layer's
# content hash, BuildKit re-runs the RUN with the cached /work/firefox-src/obj
# + ~/.mozbuild + sccache state still on disk — mach detects the existing
# build artifacts and does an incremental rebuild instead of starting from
# zero. The 3h cold compile becomes a ~5min relink.
#
# `id=` is stable so the cache survives the layer-hash invalidations that we
# trigger on every script tweak. `sharing=locked` prevents concurrent CI runs
# from corrupting each other.
# Diagnostic flags forwarded to apply-and-build.sh. Default off; the
# workflow's workflow_dispatch inputs flip them. ARG values land in the heavy
# RUN's env via the bash invocation below.
ARG PW_JUGGLER_ORDER_FIRST=false
ARG PW_JUGGLER_CATEGORY_RENAME=false
ARG PW_SKIP_APORTS=false
ARG PW_ENABLE_TESTS=false
ARG PW_JUGGLER_INSTRUMENT=false
# generate | use | '' — see apply-and-build.sh.
ARG PGO_STAGE=
COPY --from=pgo-profile-in /pgo /work/pgo

RUN --mount=type=cache,target=/work/firefox-src/obj,id=ffx-obj,sharing=locked \
    --mount=type=cache,target=/root/.mozbuild,id=ffx-mozbuild,sharing=locked \
    --mount=type=cache,target=/root/.cache/sccache,id=ffx-sccache,sharing=locked \
    set -a && . /work/versions.env && set +a \
    && PW_JUGGLER_ORDER_FIRST="$PW_JUGGLER_ORDER_FIRST" \
       PW_JUGGLER_CATEGORY_RENAME="$PW_JUGGLER_CATEGORY_RENAME" \
       PW_SKIP_APORTS="$PW_SKIP_APORTS" \
       PW_ENABLE_TESTS="$PW_ENABLE_TESTS" \
       PW_JUGGLER_INSTRUMENT="$PW_JUGGLER_INSTRUMENT" \
       PGO_STAGE="$PGO_STAGE" \
       bash /work/firefox/scripts/apply-and-build.sh /work

# ---- PGO profile ----------------------------------------------------------
# What a PGO_STAGE=generate build leaves behind: the merged profile and the
# jarlog, a few MB. The `use` build pulls it back in as PGO_PROFILE_IMAGE.
FROM scratch AS pgo-profile
COPY --from=firefox-builder /work/pgo /pgo

# ---- Artifact ----------------------------------------------------------------
# Scratch image with just the built firefox/ dist tree under /firefox.
# apply-and-build.sh stages the dist at /work/firefox-dist (out of the cache
# mount, so it survives into this image's filesystem). The artifact stage just
# COPYs from there.
FROM scratch AS artifact
COPY --from=firefox-builder /work/firefox-dist /firefox
# The unstripped libxul.so bundle-dist.sh set aside; consumers COPY /firefox
# only, so this never reaches a shipped image (browser-perf-record.yml reads it).
COPY --from=firefox-builder /work/firefox-symbols /symbols
