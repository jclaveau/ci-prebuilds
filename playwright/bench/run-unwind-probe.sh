#!/bin/sh
# Runs the launch kernel with unwind-counter.c preloaded, inside whichever
# image invokes it, and prints one `unwind-counter` line per process that ran.
#
# The preload has to be PREPENDED rather than exported: our pw_run.sh assigns
# LD_PRELOAD outright (mimalloc + fastfmod), so an exported value would be
# dropped before the browser starts. Playwright's own pw_run.sh assigns
# nothing, so there the line is inserted instead.
#
# UNWIND_OUT is a plain export because it only has to reach the browser's
# environment, which it inherits from the driver, which inherits it from here.
set -eu

probe="${PROBE_DIR:-/probe}"
so=/tmp/unwind.so
UNWIND_OUT=/tmp/unwind-out
export UNWIND_OUT
rm -rf "$UNWIND_OUT"
mkdir -p "$UNWIND_OUT"

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

# Each counter file is six little-endian 64-bit words written straight into
# shared memory, so a process that was killed still reports. od wraps its
# output, hence the newline squeeze before reading the fields.
for f in "$UNWIND_OUT"/[0-9]*; do
  [ -f "$f" ] || continue
  # -v because od collapses runs of identical lines to "*", and an all-zero
  # counter file is exactly that — the first reading lost four of six fields.
  set -- $(od -A n -v -t u8 -N 48 "$f" | tr -s ' \n' ' ')
  echo "unwind-counter pid=$(basename "$f") throws=$1 walks=$2" \
    "raises=$3 resumes=$4 forced=$5 phdr_scans=$6"
done

echo "== dl_iterate_phdr callers"
cat "$UNWIND_OUT"/callers-*.txt 2>/dev/null | sort | uniq -c | sort -rn | head -20
