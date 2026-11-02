#!/bin/bash
# Times every built arm on this runner, once per input (the harness's
# synthetic one, then each file in $OUT/inputs): ROUNDS interleaved rounds,
# the arm order rotating each round, REPS deflate+inflate pairs per arm per
# round. Writes $OUT/times/<input>/<arm>-<round>.txt.
set -euo pipefail
: "${OUT:?}" "${ROUNDS:?}" "${REPS:?}"
mapfile -t arm_list < <(ls "$OUT/arms")
input_list=(synthetic)
for input_path in "$OUT"/inputs/*; do
  [ -f "$input_path" ] || { printf "no input file in %q/inputs\n" "$OUT" >&2; exit 1; }
  input_list+=("$(basename "$input_path")")
done
for input_name in "${input_list[@]}"; do
  input_args=()
  [ "$input_name" = synthetic ] || input_args=("$OUT/inputs/$input_name")
  mkdir -p "$OUT/times/$input_name"
  for ((round_index = 0; round_index < ROUNDS; round_index++)); do
    for ((arm_offset = 0; arm_offset < ${#arm_list[@]}; arm_offset++)); do
      arm_name=${arm_list[$(((arm_offset + round_index) % ${#arm_list[@]}))]}
      "$OUT/arms/$arm_name/harness" "$REPS" "${input_args[@]}" \
        > "$OUT/times/$input_name/$arm_name-$round_index.txt"
    done
  done
done
