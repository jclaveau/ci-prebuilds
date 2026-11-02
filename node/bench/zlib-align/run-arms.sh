#!/bin/bash
# Times every built arm on this runner: ROUNDS interleaved rounds, the arm
# order rotating each round, REPS deflate+inflate pairs per arm per round.
set -euo pipefail
: "${OUT:?}" "${ROUNDS:?}" "${REPS:?}"
mapfile -t arm_list < <(ls "$OUT/arms")
mkdir -p "$OUT/times"
for ((round_index = 0; round_index < ROUNDS; round_index++)); do
  for ((arm_offset = 0; arm_offset < ${#arm_list[@]}; arm_offset++)); do
    arm_name=${arm_list[$(((arm_offset + round_index) % ${#arm_list[@]}))]}
    "$OUT/arms/$arm_name/harness" "$REPS" > "$OUT/times/$arm_name-$round_index.txt"
  done
done
