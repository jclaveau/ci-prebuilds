#!/usr/bin/env bash
# Run a probe script against a WebKit artifact, or against Playwright's own
# image as the control.
#
#   ./run-probe.sh wk-gtk-sha-<sha>                  # one of ours
#   ./run-probe.sh official                          # PW's published image
#   ./run-probe.sh official capture-permissions.cjs
#   ./run-probe.sh wk-gtk-sha-<sha> cachestorage-reload.cjs
#
# Exists because the answer depends entirely on the environment, and two ways of
# getting it wrong both look like a browser bug:
#
#   - The sandbox escape hatch is WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS (plus
#     WEBKIT_FORCE_SANDBOX=0). `WEBKIT_DISABLE_SANDBOX=1` is a spelling WebKit
#     silently ignores, so bwrap stays LIVE and enumerateDevices CRASHES the
#     page — which reads as a capture bug and is not one. That typo already cost
#     this repo the file-upload and download residuals once.
#   - Without the GST_* vars the GStreamer plugins are installed but never
#     discovered, and capture looks structurally broken. Same three values
#     conformance/build-runner.sh bakes in.
#
# Keep this in step with the EXTRA_ENV / SECURITY_FLAGS block in
# .github/workflows/pw-conformance.yml — a probe that does not match the runner
# is measuring a different browser than CI is.

set -euo pipefail

TARGET="${1:?usage: run-probe.sh <wk-tag|official> [probe.cjs]}"
PROBE="${2:-capture-permissions.cjs}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Any image carrying the musl runtime deps our artifacts need. `edge` is the
# consumer image built from this repo's main.
PROBE_BASE="${PROBE_BASE:-ghcr.io/jclaveau/alpine-dood-playwright:edge}"
PW_VERSION="${PW_VERSION:-1.62.1}"
OFFICIAL_IMAGE="${OFFICIAL_IMAGE:-mcr.microsoft.com/playwright:v${PW_VERSION}-noble}"
WK_PACKAGE="${WK_PACKAGE:-ghcr.io/jclaveau/playwright-alpine-browsers}"

[ -f "$HERE/$PROBE" ] || { echo "no such probe: $HERE/$PROBE" >&2; exit 1; }

# `official` runs unmodified — it already ships its own webkit and playwright.
# Our artifacts are payload images with no shell, so they are staged onto
# PROBE_BASE by replacing the whole minibrowser-wpe directory. Whole-directory,
# never file-by-file: the layout is FLAT (every .so beside MiniBrowser with
# RPATH=$ORIGIN), and assuming PW's nested lib/ layout has cost rounds before.
if [ "$TARGET" = "official" ]; then
  IMAGE="probe-official:${PW_VERSION}"
  WORKDIR=/root/pwc
  build_context=$(mktemp -d)
  trap 'rm -rf "$build_context"' EXIT
  cat > "$build_context/Dockerfile" <<EOF
FROM ${OFFICIAL_IMAGE}
WORKDIR ${WORKDIR}
RUN npm init -y >/dev/null && npm i playwright-core@${PW_VERSION} >/dev/null 2>&1
EOF
  docker build -q -t "$IMAGE" "$build_context" >/dev/null
else
  IMAGE="probe-${TARGET}"
  WORKDIR=/home/runner/pwc
  # The revision has to match the directory the artifact ships under. It is not
  # in versions.env — it comes from PW's browsers.json at build time — so read it
  # off the base image, which already carries exactly one webkit-<rev>.
  docker pull -q "$PROBE_BASE" >/dev/null
  WK_REV="${WK_REV:-$(docker run --rm "$PROBE_BASE" \
    sh -c 'ls -d /ms-playwright/webkit-* 2>/dev/null' | head -1 | grep -oE '[0-9]+$')}"
  [ -n "$WK_REV" ] || { echo "no webkit-<rev> in $PROBE_BASE; set WK_REV=<rev>" >&2; exit 1; }
  echo "webkit revision ${WK_REV} (from ${PROBE_BASE})"
  build_context=$(mktemp -d)
  trap 'rm -rf "$build_context"' EXIT
  cat > "$build_context/Dockerfile" <<EOF
FROM ${WK_PACKAGE}:${TARGET} AS artifact
FROM ${PROBE_BASE}
USER root
RUN rm -rf /ms-playwright/webkit-${WK_REV}/minibrowser-wpe
COPY --from=artifact /webkit/minibrowser-wpe /ms-playwright/webkit-${WK_REV}/minibrowser-wpe
RUN chmod -R a+rX /ms-playwright/webkit-${WK_REV}/minibrowser-wpe \\
 && chmod a+x /ms-playwright/webkit-${WK_REV}/minibrowser-wpe/MiniBrowser \\
              /ms-playwright/webkit-${WK_REV}/minibrowser-wpe/WPE*Process
USER runner
WORKDIR ${WORKDIR}
RUN npm init -y >/dev/null && npm i playwright-core@${PW_VERSION} >/dev/null 2>&1
EOF
  docker build -q -t "$IMAGE" "$build_context" >/dev/null
fi

echo "===== ${TARGET} — ${PROBE} ====="

# Env is per-target and must NOT be shared. The sandbox escape hatch and the
# GST_* paths below are Alpine-specific: /usr/lib/gstreamer-1.0 does not exist on
# the official noble image (it uses /usr/lib/x86_64-linux-gnu/gstreamer-1.0), and
# pointing GStreamer at an empty dir takes the browser down mid-probe — which
# reads as "official crashes on ungranted capture" and is purely our own env.
# The control runs bare, exactly as Playwright ships it.
ARTIFACT_ENV=()
if [ "$TARGET" != "official" ]; then
  # apparmor/seccomp unconfined + SYS_ADMIN + NET_ADMIN are what WebKit's bwrap
  # needs even with the escape hatch set; peeled by error, see
  # project_webkit_smoke_sandbox_strip_layers.
  ARTIFACT_ENV=(
    -e WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
    -e WEBKIT_FORCE_SANDBOX=0
    -e GST_PLUGIN_SYSTEM_PATH_1_0=/usr/lib/gstreamer-1.0
    -e GST_PLUGIN_SCANNER_1_0=/usr/libexec/gstreamer-1.0/gst-plugin-scanner
    -e GST_REGISTRY_1_0=/tmp/gst-registry.bin
  )
fi

PASSTHROUGH_ENV=()
for var in GST_DEBUG GST_DEBUG_FILE DEBUG; do
  [ -n "${!var:-}" ] && PASSTHROUGH_ENV+=(-e "$var=${!var}")
done

docker run --rm -i \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  --cap-add SYS_ADMIN --cap-add NET_ADMIN \
  "${ARTIFACT_ENV[@]+"${ARTIFACT_ENV[@]}"}" \
  "${PASSTHROUGH_ENV[@]+"${PASSTHROUGH_ENV[@]}"}" \
  -v "$HERE/$PROBE:${WORKDIR}/$(basename "$PROBE"):ro" \
  -w "$WORKDIR" \
  "$IMAGE" node "$(basename "$PROBE")"
