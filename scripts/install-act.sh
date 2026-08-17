#!/usr/bin/env bash
# Install nektos/act. Prefers the AUTHENTICATED release download, falls back to
# upstream's install.sh with jittered retries.
#
# Why: ~20 bench-act jobs (plus 4 in test-and-publish) start within seconds of each
# other and all curl the SAME raw.githubusercontent.com URL, which answers 429.
# Run 32040855731 lost 13 jobs that way, and the 429 reproduces from a dev box too
# — so it is broad anonymous rate limiting, not a CI-only blip. Retrying an
# anonymous fetch harder does not fix that; using a credential does. `gh release
# download` counts against the token's generous limit instead.
#
# It also fixes two things about the inline one-liners it replaces:
#   - `curl … | sudo bash` masked curl's exit code, so a 429 produced an empty pipe
#     and the step failed later at `act --version` with a bare 127 — nothing naming
#     the download as the cause.
#   - test-and-publish's variants used `-sSL` without `-f`, so an HTTP error BODY
#     was piped into `sudo bash`. Harmless in practice (bash chokes on HTML) but it
#     is a downloaded error page executing as root.
#
# Usage: ACT_VERSION=0.2.89 scripts/install-act.sh [bin_dir]
set -euo pipefail

VERSION="${ACT_VERSION:?ACT_VERSION must be set}"
BIN_DIR="${1:-/usr/local/bin}"
ATTEMPTS="${ACT_INSTALL_ATTEMPTS:-5}"

# Escalate only when the target is actually not writable: root-in-container needs
# no sudo, and a writable BIN_DIR (a temp dir when testing this script) must not
# require one either.
mkdir -p "$BIN_DIR" 2>/dev/null || true
SUDO=""
if [ ! -w "$BIN_DIR" ]; then
  command -v sudo >/dev/null || {
    echo "::error::$BIN_DIR is not writable and sudo is unavailable" >&2; exit 1; }
  SUDO=sudo
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

install_from_release() {
  command -v gh >/dev/null || return 1
  [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] || return 1
  case "$(uname -m)" in
    x86_64) asset=act_Linux_x86_64.tar.gz ;;
    aarch64 | arm64) asset=act_Linux_arm64.tar.gz ;;
    *) return 1 ;;
  esac
  gh release download "v${VERSION}" -R nektos/act -p "$asset" -D "$work" --clobber || return 1
  tar -xzf "${work}/${asset}" -C "$work" act || return 1
  $SUDO install -m 0755 "${work}/act" "${BIN_DIR}/act"
}

install_from_upstream_script() {
  local url="https://raw.githubusercontent.com/nektos/act/v${VERSION}/install.sh"
  local installer="${work}/install.sh"
  for attempt in $(seq 1 "$ATTEMPTS"); do
    # -f so an HTTP error is a non-zero rc instead of a saved error page; -o so the
    # rc is curl's own and not a pipeline's. --retry covers connection blips; the
    # outer loop covers 429, which needs a longer, jittered wait.
    if curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 \
            --retry 3 --retry-connrefused -o "$installer" "$url"; then
      # -f should make this unreachable, but assert before running it as root.
      head -n 1 "$installer" | grep -q '^#!' \
        || { echo "::error::downloaded act installer is not a script" >&2; return 1; }
      $SUDO bash "$installer" -b "$BIN_DIR"
      return 0
    fi
    [ "$attempt" -eq "$ATTEMPTS" ] && return 1
    # Jittered: a fixed delay just re-collides every parallel job next round.
    local delay=$(( attempt * 5 + RANDOM % 10 ))
    echo "act installer fetch failed (attempt ${attempt}/${ATTEMPTS}); retrying in ${delay}s" >&2
    sleep "$delay"
  done
  return 1
}

if install_from_release; then
  echo "act installed from the release asset (authenticated)"
elif install_from_upstream_script; then
  echo "act installed via upstream install.sh"
else
  echo "::error::could not install act ${VERSION} — release download and install.sh both failed" >&2
  exit 1
fi

"${BIN_DIR}/act" --version
