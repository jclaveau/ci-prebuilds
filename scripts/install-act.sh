#!/usr/bin/env bash
# Install act, retrying the WHOLE install rather than one of its fetches.
#
# `curl … install.sh | sudo bash` is two network operations, not one: the
# installer itself, and the release tarball the installer then downloads. A
# retry on the outer curl would not cover the inner one, and the inner one is
# where run 34019728798 died — `exit code 35`, a TLS connect error, straight
# after "found version: 0.2.89", which killed a whole nightly bench leg on a
# blip with nothing to do with the bench.
#
# Six call sites across two workflows used to paste the one-liner, so the retry
# lives here once and they all read it.
#
# Usage: ACT_VERSION=0.2.89 scripts/install-act.sh [dest_dir]

set -euo pipefail

VERSION="${ACT_VERSION:?ACT_VERSION must be set (workflow env)}"
DEST="${1:-/usr/local/bin}"
ATTEMPTS="${ACT_INSTALL_ATTEMPTS:-5}"
URL="https://raw.githubusercontent.com/nektos/act/v${VERSION}/install.sh"

n=1
while (( n <= ATTEMPTS )); do
  # pipefail makes the pipeline carry curl's exit status, so a failed download
  # is not masked by bash exiting 0 on empty input.
  if curl --proto '=https' --tlsv1.2 -sSf \
          --connect-timeout 15 --max-time 180 "$URL" \
       | sudo bash -s -- -b "$DEST"; then
    act --version
    if (( n > 1 )); then
      echo "install-act: recovered on attempt $n" >&2
    fi
    exit 0
  fi
  echo "  NETWORK: act $VERSION install failed (attempt $n/$ATTEMPTS)" >&2
  if (( n < ATTEMPTS )); then
    backoff=$(( n * 5 < 30 ? n * 5 : 30 ))
    echo "  NETWORK: sleeping ${backoff}s" >&2
    sleep "$backoff"
  fi
  n=$((n+1))
done

echo "install-act: NETWORK FAILURE — could not install act $VERSION after" >&2
echo "  $ATTEMPTS attempts. This is github.com/raw.githubusercontent.com or the" >&2
echo "  release CDN, NOT this repo's workflows." >&2
exit 1
