#!/bin/sh
# `record-image-tool <name>`: add what this layer just installed to the prebuilt-tool
# manifest `assert-prebuilt-tools-in-use` reads at the end of a consumer job.
#
# Recorded per tool: its resolved path, its version, and a size+mtime fingerprint. Both
# fields survive the layer tar into every container run, unlike the inode, which overlayfs
# renumbers — so a step that overwrites the baked binary in place with the same version is
# still caught. Nothing here is derived from a build ARG: the row describes the file that
# ended up in the image, not the version the build asked for.
set -eu

tool_name=${1:?record-image-tool needs a tool name}
[ "$#" -eq 1 ] || { echo "record-image-tool takes one tool name, got: $*" >&2; exit 1; }

tool_path=$(command -v "$tool_name") \
  || { echo "record-image-tool: $tool_name is not on PATH" >&2; exit 1; }

# -L so the row describes the file the tool actually runs from, matching what the assertion
# reads back (its stat follows symlinks too).
tool_version=$("$tool_path" --version 2>/dev/null | head -1 | sed -e 's/^v//' -e 's/[[:space:]]*$//')
[ -n "$tool_version" ] || { echo "record-image-tool: $tool_path --version printed nothing" >&2; exit 1; }
tool_size=$(stat -L -c %s "$tool_path")
tool_mtime=$(stat -L -c %Y "$tool_path")

# CI_PREBUILDS_MANIFEST exists for tests/scripts/test-prebuilt-tools-manifest.sh, which has
# no /etc to write to; the image never sets it.
manifest=${CI_PREBUILDS_MANIFEST:-/etc/ci-prebuilds/prebuilt-tools.tsv}
mkdir -p "$(dirname "$manifest")"
staged=$manifest.staged
# A later layer reinstalling a tool an earlier one recorded (the pnpm layer over the pnpm
# npm ships with node) replaces its row instead of adding a second one, so the manifest
# always names the version the finished image carries.
if [ -f "$manifest" ]; then
  awk -F'\t' -v name="$tool_name" '$1 != name' "$manifest" > "$staged"
else
  : > "$staged"
fi
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$tool_name" "$tool_path" "$tool_version" "$tool_size" "$tool_mtime" >> "$staged"
mv -f "$staged" "$manifest"
chmod 0644 "$manifest"

echo "recorded $tool_name $tool_version at $tool_path (${tool_size}B mtime=$tool_mtime)"
