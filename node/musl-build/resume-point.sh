#!/usr/bin/env bash
# Sets RESUME_IMAGE for the job's build: the stage's wip image a previous round
# pushed when make ran out of its budget, or empty for a fresh build.
#
#   resume-point.sh generate|use     reads IMAGE, TAG, ROUND, FORCE
set -euo pipefail

stage=$1
wip_image="$IMAGE:wip-$stage-$TAG"
resume_image=""
if [ "$FORCE" = true ] && [ "$ROUND" = 1 ]; then
  echo "force_build: round 1 starts fresh, $wip_image is not used"
elif docker manifest inspect "$wip_image" >/dev/null 2>&1; then
  resume_image=$wip_image
  echo "round $ROUND resumes from $wip_image"
elif [ "$ROUND" != 1 ]; then
  echo "round $ROUND was dispatched to resume, but $wip_image does not exist" >&2
  exit 1
else
  echo "round 1, no $wip_image: fresh build"
fi
echo "RESUME_IMAGE=$resume_image" >> "$GITHUB_ENV"
