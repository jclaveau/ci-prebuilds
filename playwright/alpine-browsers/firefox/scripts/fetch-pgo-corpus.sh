#!/usr/bin/env bash
# Fetch the benchmarks the PGO profile run trains on beyond what the Firefox
# tree already carries: JetStream3 (Mozilla's own `--extended-corpus`, gated
# off in-tree behind a taskcluster-only fetch) and MotionMark (Mozilla pins it
# for raptor, never for PGO).
#
# Both SHAs and sizes come from mozilla-central's
# taskcluster/kinds/fetch/benchmarks.yml, so we train on exactly the revisions
# Mozilla's own perf jobs do.
#
# Layout produced, which profileserver.py reads verbatim:
#   <dest>/JetStream/              — must be named `JetStream`, asserted upstream
#   <dest>/motionmark/MotionMark/  — mirrors the fetch's strip-components + add-prefix
#
# Usage: fetch-pgo-corpus.sh <dest_dir>
set -euo pipefail

DEST="${1:?usage: fetch-pgo-corpus.sh <dest_dir>}"

JETSTREAM_SHA="${FF_PGO_JETSTREAM_SHA:?FF_PGO_JETSTREAM_SHA must be set (versions.env)}"
JETSTREAM_SHA256="${FF_PGO_JETSTREAM_SHA256:?FF_PGO_JETSTREAM_SHA256 must be set (versions.env)}"
MOTIONMARK_SHA="${FF_PGO_MOTIONMARK_SHA:?FF_PGO_MOTIONMARK_SHA must be set (versions.env)}"
MOTIONMARK_SHA256="${FF_PGO_MOTIONMARK_SHA256:?FF_PGO_MOTIONMARK_SHA256 must be set (versions.env)}"

# $1 url, $2 expected sha256, $3 target dir. The tarball is verified BEFORE it
# is unpacked: a truncated GitHub archive that still untars would give us a
# corpus item that 404s, and a corpus item that never starts is indistinguish-
# able from one that ran (the runner closes its window on its own timeout
# either way), so the only place to catch it is here.
fetch_and_unpack() {
  local url="$1" want="$2" dir="$3"
  local tarball="$dir.tar.gz"

  echo "  $url"
  curl -fsSL "$url" -o "$tarball"

  local got
  got=$(sha256sum "$tarball" | cut -d' ' -f1)
  if [[ "$got" != "$want" ]]; then
    echo "ERROR: sha256 mismatch for $url" >&2
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    exit 1
  fi

  mkdir -p "$dir"
  tar -xzf "$tarball" -C "$dir" --strip-components=1
  rm -f "$tarball"
  echo "    -> $dir ($(du -sh "$dir" | cut -f1))"
}

echo "===== fetch PGO extended corpus into $DEST ====="
mkdir -p "$DEST"

fetch_and_unpack \
  "https://github.com/WebKit/JetStream/archive/${JETSTREAM_SHA}.tar.gz" \
  "$JETSTREAM_SHA256" "$DEST/JetStream"

fetch_and_unpack \
  "https://github.com/webkit/motionmark/archive/${MOTIONMARK_SHA}.tar.gz" \
  "$MOTIONMARK_SHA256" "$DEST/motionmark"

# The two entry points the corpus drives. Asserting them here rather than at
# profile-run time keeps a bad pin a 30-second failure instead of a 4-hour one.
for f in "$DEST/JetStream/index.html" "$DEST/JetStream/JetStreamDriver.js" \
         "$DEST/motionmark/MotionMark/index.html" \
         "$DEST/motionmark/MotionMark/resources/runner/motionmark.js"; do
  [[ -f "$f" ]] || { echo "ERROR: expected $f in the extended corpus" >&2; exit 1; }
done

echo "===== extended corpus ready ====="
