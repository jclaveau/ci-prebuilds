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
# tracks edge (`_llvmver=22` etc.) — Alpine 3.21 stable doesn't ship clang22.
# The artifact image (FROM scratch) inherits no Alpine version; the runtime
# Alpine version is the consumer's choice.
ARG ALPINE_VERSION=edge

# ---- Firefox builder ---------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS firefox-builder

# Bash + tooling for our scripts; the rest matches aports' community/firefox
# `makedepends`. Versions of clang/lld/llvm are pinned in lockstep with aports'
# `_llvmver` (read by apply-and-build.sh at build time, not hard-coded here).
RUN apk add --no-cache \
        bash curl git patch patchutils tar xz gzip jq gettext-envsubst make sccache \
        alsa-lib-dev automake bsd-compat-headers cargo cbindgen \
        clang22 clang22-libclang clang22-dev compiler-rt \
        dbus dbus-dev gettext gtk+3.0-dev hunspell-dev icu-dev \
        libevent-dev libffi-dev libjpeg-turbo-dev libnotify-dev libogg-dev \
        libtheora-dev libtool libvorbis-dev libvpx-dev libwebp-dev \
        libxcomposite-dev libxt-dev lld22 llvm22-dev m4 mesa-dev \
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
RUN --mount=type=cache,target=/work/firefox-src/obj,id=ffx-obj,sharing=locked \
    --mount=type=cache,target=/root/.mozbuild,id=ffx-mozbuild,sharing=locked \
    --mount=type=cache,target=/root/.cache/sccache,id=ffx-sccache,sharing=locked \
    set -a && . /work/versions.env && set +a \
    && bash /work/firefox/scripts/apply-and-build.sh /work

# ---- Artifact ----------------------------------------------------------------
# Scratch image with just the built firefox/ dist tree under /firefox.
# apply-and-build.sh stages the dist at /work/firefox-dist (out of the cache
# mount, so it survives into this image's filesystem). The artifact stage just
# COPYs from there.
FROM scratch AS artifact
COPY --from=firefox-builder /work/firefox-dist /firefox
