---
name: project_strip_must_precede_final_copy
description: Deleting bundled libs in a RUN layer AFTER the COPY never shrinks the published image — layer blobs are immutable; the strip/dedup must run in a staging stage the final image COPYs FROM (−103 MiB, 7bd4ab6)
metadata:
  type: project
---

`strip-bundled-libs.sh` / `strip-mesa-closure.sh` / the ICU dedup ran as `RUN`
layers *after* the `COPY --from=<producer>` that brought the bundles in. In
OCI/Docker a delete in a later layer only writes a **whiteout** into that layer's
blob — the bytes stay paid for in the earlier COPY blob. The strip layers
measured **+155 / +4,080 / +2,525 bytes** instead of the ~110 MB (+ ~225 MB Mesa)
they remove on disk, so months of dedup work never moved the published size.

**Fix (7bd4ab6):** three stages in `playwright/Dockerfile.alpine` —
`runtime-libs` (the apk set, shared so the strip's ldd gate can't diverge from
what ships) → `browsers-staged` (COPY + FF shim + both strips) → final image
`COPY --from=browsers-staged` the finished trees. 897.11 → **793.81 MiB**
compressed (ff 117.18→104.09, wk 252.65→162.70, chs unchanged), layers 21→13.
Alpine all-3-browsers went from 18 MB heavier than the official MCR image to
86 MB lighter.

**Constraints that shape the stage split:**
- Both bundles must be stripped in the SAME stage — the cross-bundle ICU dedup
  symlinks webkit's `libicu*` at firefox's, at the paths they'll occupy in the
  final image (relative symlinks, see [[project_icu_dedup_symlink_not_hardlink]]).
- COPY firefox out BEFORE webkit so those symlink targets exist. Verified that
  `COPY --from` preserves a relative symlink pointing OUTSIDE the copied subtree.
- Keep per-browser COPYs in the final stage (not one big `/ms-playwright` copy)
  so a single producer bump doesn't re-push all three browsers.

**How to apply:** measure a size change by summing **compressed layer blobs**
(`docker buildx imagetools inspect --raw <ref>` → amd64 manifest → `.layers|map(.size)`),
never `du` inside the container. If a "space saving" doesn't show up there, it's
in the wrong layer. [[project_finalize_overlay_baked_scripts]] is the sibling
trap (an edit that never reaches the image at all).
