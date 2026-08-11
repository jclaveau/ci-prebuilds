# ICU dedup must be a relative symlink, not a hardlink

The cross-bundle ICU dedup in `strip-bundled-libs.sh` (webkit → firefox, ~5.7M)
looked green locally but shipped with separate inodes in the published images.

## Root cause
CI's `docker/setup-buildx-action@v3` runs buildkitd from
`mirror.gcr.io/moby/buildkit:buildx-stable-1` (buildkitd **v0.31.2**,
docker-container driver). That buildkit serializes a cross-layer **hardlink** as a
**regular file copy** during layer export — silently undoing the dedup. The
docker-embedded builder (local `buildx --builder default`) preserves hardlinks,
which is why local repros were green.

## Fix (shipped, commit af6a232)
`strip-bundled-libs.sh` dedups via a **relative symlink** instead of `ln`:
`rm "$f"` then `ln -s "$rel${src#"$dst"/}" "$f"` (pure-bash relative path, no
coreutils — busybox `realpath` lacks `--relative-to` and busybox `ln` lacks `-r`).
Symlinks serialize as tar metadata and survive layer export; the loader resolves
the same bytes, preserving the tested==shipped-by-byte-equality parity argument.

Verified in the published image: strip RUN layer shrank 2,028,594 B → 2,525 B,
`latest` shows the 3 symlinks + exactly 1 physical ICU triple.

## Diagnostic recipe (if it regresses)
- Build log proves `hardlinked 3 identical lib(s)` ran in-container; the loss
  happens at layer export, so inspect the pushed strip-layer tar for `h`
  (hardlink) vs `l` (symlink) vs `-` (regular copy) typeflags.
- Reproduce CI's exporter: `docker buildx create --driver docker-container
  --driver-opt image=mirror.gcr.io/moby/buildkit:buildx-stable-1` + push/pull
  through a local registry; the default builder hides the bug.
- Job logs: `curl .../actions/jobs/<id>/logs` with `gh auth token` (gh run view
  --log returns 0 bytes on completed jobs).
