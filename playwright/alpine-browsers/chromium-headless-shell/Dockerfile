# syntax=docker/dockerfile:1
#
# Producer image: builds a musl-native chrome-headless-shell at the revision PW
# pins via `playwright-core@${PW_VERSION}/browsers.json`. Final artifact stage
# is FROM scratch with /chrome-headless-shell-linux64/ — the tree the consumer
# Dockerfile drops under PLAYWRIGHT_BROWSERS_PATH for PW SDK auto-discovery.
#
# Architecture mirrors playwright/alpine-browsers/firefox/Dockerfile. See the
# strategy doc (~/.claude/plans/as-alpine-is-the-synchronous-kahan.md) for the
# patterns this replays: producer/consumer split, derive-from-PW pinning, three-
# tier smoke, prebuilt-base + iter, diagnostic flags.

FROM alpine:edge AS chromium-builder

# Clang + lld + LLVM at the version aports' Chromium tracks. Aports' APKBUILD
# uses _llvmver from a single source — we mirror by pulling the same _llvmver
# at runtime from the fetched APKBUILD (see apply-and-build.sh).
# Initial install: a sufficient toolchain to bootstrap; aports' APKBUILD may
# require specific clang versions.
RUN apk add --no-cache \
        bash curl git patch patchutils tar xz gzip jq make \
        clang lld llvm \
        rust cargo \
        gn ninja-build \
        python3 py3-setuptools \
        nodejs npm \
        binutils file unzip \
        # Chromium build-time deps
        alsa-lib-dev brotli-dev cairo-dev cups-dev dbus-dev \
        ffmpeg-dev flac-dev fontconfig-dev freetype-dev gdk-pixbuf-dev \
        gtk+3.0-dev harfbuzz-dev libdrm-dev libevent-dev libffi-dev \
        libjpeg-turbo-dev libpng-dev libwebp-dev libxml2-dev libxslt-dev \
        mesa-dev minizip-dev nspr-dev nss-dev opus-dev pango-dev pciutils-dev \
        pipewire-dev pulseaudio-dev re2-dev snappy-dev \
        sqlite-dev wayland-dev libxcomposite-dev libxcursor-dev libxdamage-dev \
        libxi-dev libxrandr-dev libxss-dev libxt-dev libxtst-dev \
        bsd-compat-headers sccache

WORKDIR /work

# Stage the build artifacts: versions.env (PW_VERSION + aports refs) + scripts
# + args.gn.overlay. Order matters for layer caching: versions.env churns most,
# args.gn.overlay second, scripts third.
COPY versions.env /work/versions.env
COPY chromium-headless-shell/args.gn.overlay /work/chromium-headless-shell/args.gn.overlay
COPY chromium-headless-shell/scripts /work/chromium-headless-shell/scripts

# Fetch derive-source-of-truth: PW's browsers.json. Exports CHS_REV / CHS_VER
# as env vars for downstream RUNs (Dockerfile env scope is per-RUN, so we
# capture via `eval $(... )` inside apply-and-build.sh).
RUN set -a && . /work/versions.env && set +a \
    && bash /work/chromium-headless-shell/scripts/fetch-pw-browsers-json.sh chromium-headless-shell \
       > /work/derived.env \
    && cat /work/derived.env

# Fetch aports' community/chromium tree (APKBUILD + musl patches).
RUN set -a && . /work/versions.env && set +a \
    && bash /work/chromium-headless-shell/scripts/fetch-aports.sh /work/aports

# Fetch Chromium source. ~3 GB download + ~12 GB extracted. This is the heaviest
# layer-cacheable step; keep it before any source mutations.
RUN set -a && . /work/versions.env && . /work/derived.env && set +a \
    && bash /work/chromium-headless-shell/scripts/fetch-chromium-src.sh /work/chromium-src

# The heavy compile. Cache mounts for gn out/, sccache. obj/ doesn't persist
# across runners reliably (BuildKit cache mount limitation); the prebuilt-base
# pattern is the workaround once cold-build is green.
ARG PW_CHROMIUM_SKIP_APORTS=false
ARG PW_CHROMIUM_ENABLE_DEBUG=false
RUN --mount=type=cache,target=/work/chromium-src/chromium-src/out,id=chr-out,sharing=locked \
    --mount=type=cache,target=/root/.cache/sccache,id=chr-sccache,sharing=locked \
    set -a && . /work/versions.env && . /work/derived.env && set +a \
    && PW_CHROMIUM_SKIP_APORTS="$PW_CHROMIUM_SKIP_APORTS" \
       PW_CHROMIUM_ENABLE_DEBUG="$PW_CHROMIUM_ENABLE_DEBUG" \
       bash /work/chromium-headless-shell/scripts/apply-and-build.sh /work

# Restructure chromium-dist into the inner layout PW SDK expects
# (chrome-headless-shell-linux64/ tree).
RUN bash /work/chromium-headless-shell/scripts/stage-cache-layout.sh /work

# ---- Artifact ----------------------------------------------------------------
FROM scratch AS artifact
COPY --from=chromium-builder /work/chrome-headless-shell-linux64 /chrome-headless-shell-linux64
