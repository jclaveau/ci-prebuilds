---
name: wk-artifact-flat-lib-layout
description: Our WebKit artifact puts every bundled .so FLAT beside MiniBrowser with RPATH=$ORIGIN — there is no minibrowser-wpe/lib/, that is PW's layout, and assuming theirs cost two CI rounds in one session
metadata:
  type: project
---

```
ours      /webkit/minibrowser-wpe/{MiniBrowser,libWPEWebKit-2.0.so.1,libwpe-1.0.so.1,…}
PW's      webkit-<rev>/minibrowser-wpe/lib/{libWPEWebKit-…,libwpe-…}
                                        bin/{MiniBrowser,WPEWebProcess,…}
```

`bundle-dist.sh:5` states it: *"patchelf RPATH=$ORIGIN on both MiniBrowser +
every bundled .so (flat layout)"*, and line 65 copies each dep straight into
`$DST/`. `strip-bundled-libs.sh` is therefore invoked on the directory itself
(`… /minibrowser-wpe webkit`), not on a `lib/` under it.

**Why:** I wrote a `COPY --from=<artifact> /webkit/minibrowser-wpe/lib/` and the
build failed on a missing source — the path came from PW's locally-cached
artifact. Then the guard I added *to catch that class of mistake* counted the
same nonexistent `lib/`, printed `0` for both the stripped and the restored
image, and verified nothing. Two rounds, one wrong assumption, applied twice.

**How to apply:** to stage or restore our artifact, reuse build-runner.sh's own
`COPY --from=$IMAGE_REF /webkit /ms-playwright/webkit-$REV` rather than any
subpath — it is layout-agnostic and is exactly what the strip reverses. When
reading a layout, read `bundle-dist.sh`, never a PW install under
`~/.cache/ms-playwright`. See [[feedback_verify_raw_source_not_wrapper]].
