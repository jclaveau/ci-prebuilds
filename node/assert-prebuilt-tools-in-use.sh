#!/bin/sh
# `assert-prebuilt-tools-in-use`: report every tool the image prebuilt that the job is no
# longer running — because a step put its own copy first on PATH (actions/setup-node,
# pnpm/action-setup) or overwrote the baked binary. That is the time the image was bought
# and then paid for again as a download.
#
# What it compares: /etc/ci-prebuilds/prebuilt-tools.tsv, written at build time by
# `record-image-tool`, against what each tool name resolves to now. Path, version and a
# size+mtime fingerprint, so an in-place overwrite is caught as well as a PATH shadow.
#
#   assert-prebuilt-tools-in-use [--severity warning|error] [--snapshot <file>]
#   assert-prebuilt-tools-in-use --write-snapshot <file>
#
# --write-snapshot records what each tool resolves to right now and exits; passing that
# file back as --snapshot lets the report say a step replaced the tool *during* the job
# rather than before it. `.github/actions/prepare` drives both halves.
#
# --severity governs findings, never the ability to run: a missing or unparseable manifest,
# an unknown flag and a bad --severity value all exit 1 in both modes. Default `error` —
# a deliberate call to this script is a gate. The prepare action passes its own default.
set -eu

# CI_PREBUILDS_MANIFEST exists for tests/scripts/test-prebuilt-tools-manifest.sh; the image
# never sets it, and neither does the prepare action.
manifest=${CI_PREBUILDS_MANIFEST:-/etc/ci-prebuilds/prebuilt-tools.tsv}
severity=${CI_PREBUILDS_ASSERT_SEVERITY:-error}
snapshot=
write_snapshot=

while [ $# -gt 0 ]; do
  case $1 in
    --severity) severity=${2:?--severity needs a value}; shift 2 ;;
    --severity=*) severity=${1#*=}; shift ;;
    --snapshot) snapshot=${2:?--snapshot needs a path}; shift 2 ;;
    --snapshot=*) snapshot=${1#*=}; shift ;;
    --write-snapshot) write_snapshot=${2:?--write-snapshot needs a path}; shift 2 ;;
    --write-snapshot=*) write_snapshot=${1#*=}; shift ;;
    *) echo "assert-prebuilt-tools-in-use: unknown argument $1" >&2; exit 1 ;;
  esac
done

case $severity in
  warning|error) ;;
  *) echo "assert-prebuilt-tools-in-use: --severity is warning or error, got $severity" >&2
     exit 1 ;;
esac

[ -f "$manifest" ] || {
  echo "assert-prebuilt-tools-in-use: no $manifest — this is not a ci-prebuilds image" \
       "at or above the node layer" >&2
  exit 1
}
# A row that does not carry all five fields means record-image-tool and this script
# disagree about the format; guessing which field is which would report nonsense.
malformed=$(awk -F'\t' 'NF != 5 { print FNR": "$0 }' "$manifest")
[ -z "$malformed" ] || {
  echo "assert-prebuilt-tools-in-use: $manifest has rows that are not 5 tab-separated" \
       "fields:" >&2
  echo "$malformed" >&2
  exit 1
}

resolve_tool() {
  command -v "$1" 2>/dev/null || true
}

if [ -n "$write_snapshot" ]; then
  : > "$write_snapshot"
  while IFS="$(printf '\t')" read -r tool_name _ _ _ _; do
    printf '%s\t%s\n' "$tool_name" "$(resolve_tool "$tool_name")" >> "$write_snapshot"
  done < "$manifest"
  echo "snapshotted $(wc -l < "$write_snapshot" | tr -d ' ') prebuilt tools to $write_snapshot"
  exit 0
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
rows=$work_dir/rows.tsv
: > "$rows"

while IFS="$(printf '\t')" read -r tool_name baked_path baked_version baked_size baked_mtime; do
  live_path=$(resolve_tool "$tool_name")
  snapshot_path=
  if [ -n "$snapshot" ] && [ -f "$snapshot" ]; then
    snapshot_path=$(awk -F'\t' -v name="$tool_name" '$1 == name { print $2 }' "$snapshot")
  fi

  if [ -z "$live_path" ]; then
    state=MISSING
    note="the image installed $tool_name at $baked_path and nothing answers to the name any more"
    printf '%s\t%s\t%s\t%s\t%s\n' "$tool_name" "-" "-" "$state" "$note" >> "$rows"
    continue
  fi

  if [ "$live_path" != "$baked_path" ]; then
    state=REPLACED
    if [ -n "$snapshot_path" ] && [ "$snapshot_path" = "$baked_path" ]; then
      note="was the image's $baked_path at prepare and resolves to $live_path by the end of the job — a step installed its own"
    else
      note="the image installed it at $baked_path but the job resolves $live_path — a step installed its own"
    fi
  else
    live_size=$(stat -L -c %s "$live_path" 2>/dev/null || echo -)
    live_mtime=$(stat -L -c %Y "$live_path" 2>/dev/null || echo -)
    if [ "$live_size" = "$baked_size" ] && [ "$live_mtime" = "$baked_mtime" ]; then
      state=image
      note=
    else
      state=REPLACED
      note="$baked_path is no longer the file the image baked (${baked_size}B mtime=$baked_mtime, now ${live_size}B mtime=$live_mtime) — a step overwrote it in place"
    fi
  fi

  # Only a finding pays for the exec: a tool that matches on path, size and mtime cannot be
  # running a different version than the row already names.
  if [ "$state" = image ]; then
    live_version=$baked_version
  else
    live_version=$("$live_path" --version 2>/dev/null | head -1 | sed -e 's/^v//' -e 's/[[:space:]]*$//')
    [ -n "$live_version" ] || live_version='?'
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$tool_name" "$live_path" "$live_version" "$state" "$note" >> "$rows"
done < "$manifest"

awk -F'\t' '
  { name[NR]=$1; path[NR]=$2; version[NR]=$3; state[NR]=$4
    if (length($1) > w1) w1 = length($1)
    if (length($2) > w2) w2 = length($2)
    if (length($3) > w3) w3 = length($3) }
  # The widths go into the format string rather than through %-*s: busybox awk (alpine) and
  # mawk (ubuntu) both run this, and only one of them is gawk.
  END { fmt = "  %-" w1 "s  %-" w2 "s  %-" w3 "s  %s\n"
        for (i = 1; i <= NR; i++) printf fmt, name[i], path[i], version[i], state[i] }
' "$rows"

finding_count=$(awk -F'\t' '$4 != "image" { n++ } END { print n + 0 }' "$rows")
tool_count=$(awk 'END { print NR + 0 }' "$rows")

if [ "$finding_count" -gt 0 ]; then
  while IFS="$(printf '\t')" read -r tool_name _ _ state note; do
    [ "$state" = image ] && continue
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::$severity::$tool_name $note"
    else
      echo "$severity: $tool_name $note" >&2
    fi
  done < "$rows"
fi

if [ "$finding_count" -eq 0 ]; then
  verdict="$tool_count prebuilt tools checked, all still the image's"
elif [ "$severity" = warning ]; then
  verdict="$tool_count prebuilt tools checked, $finding_count replaced — severity=warning, not failing the job"
else
  verdict="$tool_count prebuilt tools checked, $finding_count replaced — severity=error"
fi
echo "$verdict"

# GHA has no "unstable" conclusion, so a warning-mode finding would otherwise live only in a
# collapsed step log.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ "$finding_count" -gt 0 ]; then
  {
    echo "### Prebuilt tools replaced during the job"
    echo
    echo "| tool | resolves to | version | state |"
    echo "| --- | --- | --- | --- |"
    awk -F'\t' '{ printf "| %s | `%s` | %s | %s |\n", $1, $2, $3, $4 }' "$rows"
    echo
    echo "$verdict"
  } >> "$GITHUB_STEP_SUMMARY"
fi

[ "$finding_count" -eq 0 ] && exit 0
[ "$severity" = warning ] && exit 0
exit 1
