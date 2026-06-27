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
        bash curl git patch patchutils tar xz gzip jq make perl \
        bison flex gperf findutils elfutils elfutils-dev pax-utils \
        # LLVM toolchain — versioned to match aports' clang patches; _llvmver=22
        # on alpine:edge today. apply-and-build.sh reads the same _llvmver from
        # aports' APKBUILD and sets clang_base_path accordingly.
        clang22 clang22-dev clang22-rtlib lld22 llvm22 \
        rust cargo rust-bindgen rustfmt \
        gn ninja-build samurai \
        python3 py3-setuptools \
        nodejs npm esbuild \
        binutils file unzip linux-headers \
        bsd-compat-headers sccache \
        # Chromium build-time deps — list mirrors aports' makedepends minus
        # qt6/cups/libsecret/libusb/pipewire/pulseaudio (headless_shell doesn't
        # link any of those). If something pkg-config-trips at gn gen we add
        # it; first-pass batch is sized to cover the assertions seen so far.
        alsa-lib-dev brotli-dev bzip2-dev cairo-dev crc32c-dev curl-dev \
        dav1d-dev dbus-dev dbus-glib-dev double-conversion-dev \
        eudev-dev ffmpeg-dev flac-dev flatbuffers-dev fontconfig-dev \
        freetype-dev gdk-pixbuf-dev gtk+3.0-dev harfbuzz-dev highway-dev \
        hwdata-dev jpeg-dev jsoncpp-dev krb5-dev lcms2-dev libbsd-dev \
        libcap-dev libdrm-dev libevdev-dev libevent-dev libexif-dev \
        libffi-dev libgcrypt-dev libjpeg-turbo-dev libpng-dev libusb-dev \
        libva-dev libwebp-dev libxml2-dev libxslt-dev mesa-dev minizip-dev \
        nspr-dev nss-dev openh264-dev opus-dev pango-dev pciutils-dev \
        re2-dev simdutf-dev snappy-dev speex-dev sqlite-dev wayland-dev \
        libxcomposite-dev libxcursor-dev libxdamage-dev libxi-dev \
        libxinerama-dev libxrandr-dev libxscrnsaver-dev libxt-dev libxtst-dev

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
# sccache GHA backend: BuildKit mount=type=cache is LOCAL to the runner. On
# fresh GHA runners (the common case) it starts empty, so chromium rebuilds
# fully every iter (6h cap on hosted runners). Mirror aports' cc_wrapper=ccache
# strategy with sccache pointed at the GHA Actions Cache backend, which
# survives across runs and is the only viable persistent-cache target on
# hosted runners. Token + URL are GHA-provided env vars that we mount as
# build secrets here. Set SCCACHE_GHA_ENABLED inside the RUN so chromium's
# cc_wrapper invocation picks the GHA backend.
RUN --mount=type=cache,target=/work/chromium-out,id=chr-out,sharing=locked \
    --mount=type=cache,target=/root/.cache/sccache,id=chr-sccache,sharing=locked \
    --mount=type=secret,id=actions_runtime_token \
    --mount=type=secret,id=actions_results_url \
    set -a && . /work/versions.env && . /work/derived.env && set +a \
    && export SCCACHE_GHA_ENABLED=true \
    && export ACTIONS_RUNTIME_TOKEN="$(cat /run/secrets/actions_runtime_token 2>/dev/null || echo)" \
    && export ACTIONS_RESULTS_URL="$(cat /run/secrets/actions_results_url 2>/dev/null || echo)" \
    && if [ -z "$ACTIONS_RUNTIME_TOKEN" ] || [ -z "$ACTIONS_RESULTS_URL" ]; then \
         echo "WARN: GHA cache env not provided — sccache will use local mount only" >&2; \
         unset SCCACHE_GHA_ENABLED; \
       else \
         echo "sccache GHA backend enabled (token len=${#ACTIONS_RUNTIME_TOKEN}, url=$ACTIONS_RESULTS_URL)"; \
       fi \
    && PW_CHROMIUM_SKIP_APORTS="$PW_CHROMIUM_SKIP_APORTS" \
       PW_CHROMIUM_ENABLE_DEBUG="$PW_CHROMIUM_ENABLE_DEBUG" \
       bash /work/chromium-headless-shell/scripts/apply-and-build.sh /work

# Restructure chromium-dist into the inner layout PW SDK expects
# (chrome-headless-shell-linux64/ tree).
RUN bash /work/chromium-headless-shell/scripts/stage-cache-layout.sh /work

# ---- Artifact ----------------------------------------------------------------
FROM scratch AS artifact
COPY --from=chromium-builder /work/chrome-headless-shell-linux64 /chrome-headless-shell-linux64
