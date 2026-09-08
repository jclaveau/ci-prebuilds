#!/bin/sh
# Runs the launch kernel with unwind-counter.c preloaded, inside whichever
# image invokes it, and leaves the per-process counts on stderr.
#
# The preload has to be PREPENDED rather than exported: our pw_run.sh assigns
# LD_PRELOAD outright (mimalloc + fastfmod), so an exported value would be
# dropped before the browser starts. Playwright's own pw_run.sh assigns
# nothing, so there the line is inserted instead.
set -eu

probe="${PROBE_DIR:-/probe}"
so=/tmp/unwind.so

if command -v apk >/dev/null 2>&1; then
  apk add --no-cache gcc musl-dev >/dev/null 2>&1
else
  apt-get update >/dev/null 2>&1
  apt-get install -y gcc >/dev/null 2>&1
fi

gcc -O2 -fPIC -shared -o "$so" "$probe/unwind-counter.c" -ldl

for w in /ms-playwright/webkit-*/pw_run.sh; do
  [ -f "$w" ] || continue
  if grep -q 'LD_PRELOAD=' "$w"; then
    sed -i "s|LD_PRELOAD=|LD_PRELOAD=$so:|" "$w"
  else
    sed -i "2i export LD_PRELOAD=$so" "$w"
  fi
  echo "patched $w:"
  grep -n LD_PRELOAD "$w"
done

NODE_PATH="$(sh /pwscripts/global-node-path.sh)"
export NODE_PATH
node -e 'require("playwright")' 2>/dev/null \
  || npm install -g --no-fund --no-audit "playwright@$PW_VERSION" >/dev/null 2>&1

node "$probe/wk-hotloop.cjs" --browser webkit --kernel launch \
  --seconds "${SECS:-20}"
