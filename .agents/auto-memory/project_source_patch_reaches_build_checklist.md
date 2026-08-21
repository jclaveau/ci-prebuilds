---
name: source-patch-reaches-build-checklist
description: Two-point pre-dispatch check that a source-only patch actually executes in the browser build — image tag must be sha-scoped and the script must be COPYed before the RUN that invokes it
metadata:
  type: project
---

Before dispatching a multi-hour browser build for a **source-only** patch
(prep-source.sh, an overlay, a patched script), verify both:

1. **Is the intermediate image tag sha-scoped?**
   `build-webkit-source-prep` outputs `tag: wk-src-sha-${{ github.sha }}` — a new
   commit forces a fresh image. A tag keyed only on an upstream pin (PW rev)
   does NOT change when you edit source, so the build silently reuses the stale
   base and the patch is inert. That is exactly
   [[project_ff_prebuilt_base_pin_only_tag_staleness]].
2. **Is the script COPYed before the RUN that executes it?**
   `Dockerfile.source-prep` COPYs `prep-source.sh` (line ~82) then RUNs it
   (line ~93), so editing it busts the COPY layer. A script that is baked
   earlier and only re-COPYed by a *later* Dockerfile is inert on the stage that
   matters — [[project_finalize_overlay_baked_scripts]].

Audit status: webkit + chromium are sha-scoped and safe
([[project_chromium_webkit_base_tag_audit_safe]]); firefox was the sole
pin-only-tag instance.

**Why:** a wrong answer to either costs a full round (4.5 h WPE, up to ~20 h
chromium) and — worse — produces a *green* build that doesn't contain the fix,
which then reads as "the patch didn't work".

**How to apply:** run both greps in the ~2 minutes before `gh workflow run`;
also dry-run the patch function against reconstructed sources first
([[feedback_extract_file_content_from_diff]]) so anchor misses surface locally
instead of 40 minutes into source-prep.
