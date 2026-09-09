#!/usr/bin/env bash
# Fill a per-CPU-model quota of runtime-perf draws, by dispatching until the
# fleet hands them out.
#
# GHA gives no way to ask for a runner model, and the alpine/official ratio is
# not portable across silicon: chromium's two worst rows, `layout` and
# `screenshot`, swap which one is worse between an EPYC 9V74 and an EPYC 7763.
# So "chromium screenshot is 1.26x" is only a claim about one machine unless
# several models were drawn, and drawing them is a sampling problem — the mix
# observed on this repo is roughly 7763 50%, 9V74 25%, 8573C 10%, 8370C 10%,
# 6973P-C 5%, so a 10% model needs ~10 draws before it turns up once.
#
# That is affordable only because perf-probe.yml checks its own runner before
# pulling anything: an unwanted draw costs ~20 s instead of ~10-18 min. This
# script closes the loop around it — tally what has been collected, dispatch
# only for the models and browsers still short, repeat.
#
# usage: sample-cpu-models.sh --image <ref> [options]
#
#   --image REF        our image to measure (required)
#   --browsers CSV     default chromium,firefox,webkit
#   --models CSV       CPU substrings to cover, default 7763,9V74,8573C
#   --draws N          draws wanted per (browser, model), default 2
#   --runs N           probe repetitions inside each draw, default 10
#   --replicates N     draws attempted per browser per round, default 6
#   --max-rounds N     give up after this many dispatches, default 8
#   --ref BRANCH       branch to dispatch on, default main
#   --state DIR        accumulates every round, default tmp/cpu-sampling/<image>
set -euo pipefail

REPO="${REPO:-jclaveau/ci-prebuilds}"
HERE="$(cd "$(dirname "$0")" && pwd)"

IMAGE="" BROWSERS="chromium,firefox,webkit" MODELS="7763,9V74,8573C"
DRAWS=2 RUNS=10 REPLICATES=6 MAX_ROUNDS=8 REF="main" STATE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --browsers) BROWSERS="$2"; shift 2 ;;
    --models) MODELS="$2"; shift 2 ;;
    --draws) DRAWS="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --replicates) REPLICATES="$2"; shift 2 ;;
    --max-rounds) MAX_ROUNDS="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$IMAGE" ] || { echo "--image is required" >&2; exit 2; }
[ -n "$STATE" ] || STATE="tmp/cpu-sampling/$(tr -c '[:alnum:]' '-' <<< "$IMAGE")"
mkdir -p "$STATE"

coverage() {
  python3 "$HERE/../playwright/bench/cpu-coverage.py" "$STATE" \
    --models "$MODELS" --browsers "$BROWSERS" --target "$DRAWS" "$@"
}

echo "state: $STATE"
coverage

for round in $(seq 1 "$MAX_ROUNDS"); do
  want_models="$(coverage --short-models)"
  if [ -z "$want_models" ]; then
    echo "quota met: every browser has $DRAWS draws on each of $MODELS"
    exit 0
  fi
  want_browsers="$(coverage --short-browsers)"

  echo
  echo "=== round $round/$MAX_ROUNDS — chasing [$want_models] for [$want_browsers]"
  out="$("$HERE/dispatch-once.sh" perf-probe.yml "$REF" \
    -f image="$IMAGE" \
    -f browsers="$want_browsers" \
    -f runs="$RUNS" \
    -f replicates="$REPLICATES" \
    -f want_cpus="$want_models" \
    -f label="cpu sampling round $round — chasing $want_models")"
  echo "$out"
  id="${out##*/}"
  case "$id" in
    ''|*[!0-9]*) echo "could not read a run id out of the dispatch" >&2; exit 1 ;;
  esac

  # 2 h: a full round is one 10-18 min probe plus however long the queue is,
  # and a round that hangs past that is a problem to look at, not to wait out.
  status=""
  for _ in $(seq 1 240); do
    sleep 30
    status="$(gh run view "$id" -R "$REPO" --json status --jq .status 2>/dev/null || echo)"
    # `[ x ] && break` would return 1 on the false branch and trip `set -e`.
    if [ "$status" = completed ]; then break; fi
  done
  if [ "$status" != completed ]; then
    echo "run $id still $status after 2 h — stopping" >&2
    exit 1
  fi

  # A round in which every draw was rejected publishes no artifact, and that is
  # a normal outcome of rejection sampling, not a failure to report.
  if gh run download "$id" -R "$REPO" -n runtime-perf -D "$STATE/run-$id" 2>/dev/null; then
    echo "collected run $id"
  else
    echo "run $id produced no draw on [$want_models]"
  fi
  coverage
done

echo
echo "gave up after $MAX_ROUNDS rounds — coverage above" >&2
exit 1
