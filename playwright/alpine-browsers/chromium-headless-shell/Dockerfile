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
        # compiler-rt, not clang22-rtlib: edge dropped the versioned rtlib
        # subpackage once it started shipping clang23, and now serves every
        # installed clang from one unversioned `compiler-rt` (23.1.1 today).
        # `clang22-rtlib (no such package)` took every chromium setup stage red
        # on 2026-09-10 — runs 34492737706 and 34492771785 — on branches whose
        # own diffs touched none of this.
        clang22 clang22-dev lld22 llvm22 compiler-rt \
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
        simdutf-dev snappy-dev speex-dev sqlite-dev wayland-dev \
        libxcomposite-dev libxcursor-dev libxdamage-dev libxi-dev \
        libxinerama-dev libxrandr-dev libxscrnsaver-dev libxt-dev libxtst-dev

# Give clang22 a builtins archive. `compiler-rt` replaced clang22-rtlib in #208
# and unpacks only under /usr/lib/llvm23, so clang22's own resource dir has no
# libclang_rt.builtins-x86_64.a and chromium's link stops before it starts:
#
#   ninja: file is missing and not created by any action:
#     '.../usr/lib/llvm22/lib/clang/22/lib/linux/libclang_rt.builtins-x86_64.a'
#
# (run 34498782299 r1, 19s in). Chromium links compiler-rt builtins whatever
# is_cfi and the sanitizers say, so no gn arg avoids this. aports' own chromium
# is broken the same way right now — its APKBUILD still lists clang$_llvmver-rtlib
# at _llvmver=22 — so there is no upstream recipe to copy yet.
#
# Builtins are the libgcc-equivalent primitives (__udivti3 and friends) with a
# stable ABI, so serving clang22 from clang23's archive is safe; verified in
# alpine:edge by linking and running an __int128 division through
# `-rtlib=compiler-rt -fuse-ld=lld`. The final print is an assertion: if edge
# ships clang22-rtlib again, or moves compiler-rt, this fails the build here
# rather than 19s into a five-hour round.
RUN set -eux; \
    want=/usr/lib/llvm22/lib/clang/22/lib/linux; \
    if [ ! -e "$want/libclang_rt.builtins-x86_64.a" ]; then \
      have="$(find /usr/lib/llvm*/lib/clang/*/lib -name 'libclang_rt.builtins-x86_64.a' \
                -print 2>/dev/null | sort -V | tail -1)"; \
      [ -n "$have" ]; \
      mkdir -p "$(dirname "$want")"; \
      ln -sfn "$(dirname "$have")" "$want"; \
    fi; \
    test -e "$want/libclang_rt.builtins-x86_64.a"; \
    /usr/lib/llvm22/bin/clang -print-runtime-dir

# Alpine edge ships sccache 0.15.0-r0 with broken GHA v1 cache backend
# (see project_sccache_ghac_readonly_v18). Override with upstream musl 0.16.0
# which uses v2 backend. /usr/local/bin PATH precedence overrides apk's copy.
RUN curl -sSL "https://github.com/mozilla/sccache/releases/download/v0.16.0/sccache-v0.16.0-x86_64-unknown-linux-musl.tar.gz" \
      | tar xz -C /tmp \
 && install -m755 /tmp/sccache-v0.16.0-x86_64-unknown-linux-musl/sccache /usr/local/bin/sccache \
 && rm -rf /tmp/sccache-v0.16.0-x86_64-unknown-linux-musl \
 && sccache --version

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

ARG PW_CHROMIUM_SKIP_APORTS=false
ARG PW_CHROMIUM_ENABLE_DEBUG=false

# ---- Source prep (patches + gn gen) -----------------------------------------
# Runs apply-and-build.sh up to and including gn gen, then exits via
# PW_CHROMIUM_SKIP_NINJA=1. obj/ now lives in the image filesystem (NOT a
# cache mount) so each subsequent ninja RUN's partial obj/ state is captured
# in its own Docker layer and persists across CI runs via cache-to=registry.
# sccache cache mount is intra-build only; persistence comes from
# SCCACHE_GHA_ENABLED + Actions Cache backend.
RUN --mount=type=cache,target=/root/.cache/sccache,id=chr-sccache,sharing=locked \
    --mount=type=secret,id=actions_runtime_token \
    --mount=type=secret,id=actions_results_url \
    set -a && . /work/versions.env && . /work/derived.env && set +a \
    && export SCCACHE_GHA_ENABLED=true \
    && export ACTIONS_RUNTIME_TOKEN="$(cat /run/secrets/actions_runtime_token 2>/dev/null || echo)" \
    && export ACTIONS_RESULTS_URL="$(cat /run/secrets/actions_results_url 2>/dev/null || echo)" \
    && if [ -z "$ACTIONS_RUNTIME_TOKEN" ] || [ -z "$ACTIONS_RESULTS_URL" ]; then \
         echo "WARN: GHA cache env not provided — sccache will use local mount only" >&2; \
         unset SCCACHE_GHA_ENABLED; \
       fi \
    && PW_CHROMIUM_SKIP_APORTS="$PW_CHROMIUM_SKIP_APORTS" \
       PW_CHROMIUM_ENABLE_DEBUG="$PW_CHROMIUM_ENABLE_DEBUG" \
       PW_CHROMIUM_SKIP_NINJA=1 \
       bash /work/chromium-headless-shell/scripts/apply-and-build.sh /work

# ---- Resumable ninja rounds --------------------------------------------------
# Chromium 148 cold-build is ~13h on 4-vCPU hosted runner; GHA's 6h job cap is
# infrastructure-level (timeout-minutes is silently clamped). Solution: split
# ninja into multiple resumable rounds. Each `timeout 18000 ninja || true`
# runs for up to 5h then exits 0, committing whatever obj/ files were written
# as a Docker layer. cache-to=registry,mode=max pushes the layer. Next CI run:
# cache-from restores prior layers (each ~2-15GB but persistent across iters),
# and the next ninja round resumes from existing obj/ state. After enough
# rounds (typically 3-4 cold cycles, then warm-cache iters), the final
# `RUN ninja` completes and fails the build if anything's missing.
#
# Each ninja round needs its own --mount=secret since BuildKit doesn't
# propagate secrets across RUNs.
# Resumable ninja rounds — each is a Docker layer; cache-to=registry persists
# partial obj/ across CI iters; the final round fails the build if anything
# is still missing. See playwright/alpine-browsers/chromium-headless-shell/
# scripts/ninja-resume.sh for the full mechanism.
RUN --mount=type=cache,target=/root/.cache/sccache,id=chr-sccache,sharing=locked \
    --mount=type=secret,id=actions_runtime_token \
    --mount=type=secret,id=actions_results_url \
    bash /work/chromium-headless-shell/scripts/ninja-resume.sh /work round-1

RUN --mount=type=cache,target=/root/.cache/sccache,id=chr-sccache,sharing=locked \
    --mount=type=secret,id=actions_runtime_token \
    --mount=type=secret,id=actions_results_url \
    bash /work/chromium-headless-shell/scripts/ninja-resume.sh /work round-2

RUN --mount=type=cache,target=/root/.cache/sccache,id=chr-sccache,sharing=locked \
    --mount=type=secret,id=actions_runtime_token \
    --mount=type=secret,id=actions_results_url \
    bash /work/chromium-headless-shell/scripts/ninja-resume.sh /work final final

# Stage cache layout (move binary + assets into expected dir tree)
RUN bash /work/chromium-headless-shell/scripts/stage-cache-layout.sh /work

# ---- Artifact ----------------------------------------------------------------
FROM scratch AS artifact
COPY --from=chromium-builder /work/chrome-headless-shell-linux64 /chrome-headless-shell-linux64
