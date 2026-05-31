---
name: project-docker-build-context-per-image
description: Each image's Docker build context is `./<image>/`, not the repo root — COPY paths resolve from there, so cross-image shared scripts must be inlined or duplicated
metadata:
  type: project
---

The publish workflow builds each image with its own subdirectory as the build
context (e.g. `docker build ubuntu-gha-tools/`). So `COPY scripts/foo` in
`ubuntu-gha-tools/Dockerfile` resolves to `ubuntu-gha-tools/scripts/foo`, NOT
`<repo-root>/scripts/foo`.

**Why this matters:** a repo-root `scripts/` directory is invisible to the image
build. The CI error is unambiguous:
`failed to compute cache key … "/scripts/<file>": not found`. Happened once,
caught in TP, fixed by inlining.

**How to apply:** when adding a shared snippet to multiple Dockerfiles (e.g.
the `nss-wrapper-setup` helper for both ubuntu and alpine):

- **Preferred** — inline via BuildKit heredoc, identical in each Dockerfile:

  ```dockerfile
  # syntax=docker/dockerfile:1   # already at the top of these images
  RUN <<'EOF' bash
  cat > /usr/local/bin/<helper> <<'SCRIPT'
  #!/bin/sh
  ...
  SCRIPT
  chmod 0755 /usr/local/bin/<helper>
  EOF
  ```

  Comment in the Dockerfile that the inlined block is "kept identical to
  `<sibling-image>/Dockerfile`" so future edits cross-update both.

- **Alternative** — ship per-image copies under `./<image>/scripts/` and
  `COPY scripts/<file> …`. Avoids the heredoc but doubles maintenance and
  drifts more easily.

NOT viable: a repo-root `scripts/` directory + a single COPY. The build context
won't see it.
