#!/bin/sh
# Every JS action of a GHA `container:` job execs the runner's own musl node, read from the host
# runner's externals, bind-mounted read-only on `/__e`. On a fresh VM nothing has read that 126 MiB
# binary yet (the runner itself ran its glibc one), so the job's first JS action demand-pages all of
# it off the host disk. Pointing the path it execs at the image's node instead removes that read:
# the image's layers are already in the page cache that pulled them. 3.341 -> 0.249 s to the first
# action's start, 10 jobs an arm (run 43293915953, `node-externals-volume-ab.yml`).
#
# The symlink alone is invisible at runtime, since `/__e` comes from the host. It reaches the job
# through a `VOLUME` on this same directory: docker seeds an image-declared volume from the image's
# content at `docker create`, and that child mount stays mounted under the runner's own `/__e` bind.
#
# The directory is the one the runner resolves for the action's declared runtime: `node<major>` plus
# `_alpine` on a musl OS. A runner that forces another major than the one baked here execs its own
# node again and the gain silently goes away, so test-and-publish asserts that a real JS action ran
# on this node, not just that the symlink exists.
set -eu

externals_node_dir=${1:-}

case "$externals_node_dir" in
  '')
    echo "link-node-into-runner-externals needs the runner externals node directory as its" \
      "argument, e.g. /__e/node24_alpine" >&2
    exit 1
    ;;
  /*) ;;
  *)
    echo "$externals_node_dir is relative, and the runner reads this path from the job" \
      "container's root, so it must be absolute" >&2
    exit 1
    ;;
esac

# Shell-only, no sed: the refusals below must survive a PATH with nothing on it.
refuse_directory_shape() {
  echo "$externals_node_dir does not end in node<major>_alpine, so no runtime the runner" \
    "resolves would exec it" >&2
  exit 1
}

externals_node_basename=${externals_node_dir##*/}
externals_node_major=${externals_node_basename#node}
externals_node_major=${externals_node_major%_alpine}

case "$externals_node_basename" in
  node*_alpine) ;;
  *) refuse_directory_shape ;;
esac

case "$externals_node_major" in
  '' | *[!0-9]*) refuse_directory_shape ;;
esac

node_path=$(command -v node) || {
  echo "node is missing from this image, so there is nothing to link into $externals_node_dir" >&2
  exit 1
}

mkdir -p "$externals_node_dir/bin"
ln -sfn "$node_path" "$externals_node_dir/bin/node"

image_node_version=$("$node_path" -p process.versions.node)
linked_node_version=$("$externals_node_dir/bin/node" -p process.versions.node)
if [ "$linked_node_version" != "$image_node_version" ]; then
  echo "$externals_node_dir/bin/node runs node $linked_node_version, not the image's" \
    "$image_node_version" >&2
  exit 1
fi

echo "node $image_node_version linked at $externals_node_dir/bin/node -> $node_path"
