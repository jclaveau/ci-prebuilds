---
name: alpine-no-historical-apk-archive
description: alpine:edge ships only current apk pkgver; dl-cdn 404s historical versions, aports CI artifacts not retained — no way to fetch chromium 147.x once edge moved to 148.x
metadata:
  type: project
---

**Constraint:** Alpine has **no historical apk archive** for community packages. Implications:
- `dl-cdn.alpinelinux.org/.../<pkg>-<oldver>.apk` → 404 once edge bumps the pkgver.
- `gitlab.alpinelinux.org` aports CI: APKBUILD-edit MRs trigger `merge_request_event/skipped` pipelines; no build artifacts retained.
- No date-snapshotted `alpine:edge` on Docker Hub (snapshots are tagged by minor `alpine:3.X`, which don't include edge's chromium).

**Practical effect:** The producer can build chromium-headless-shell from whatever `alpine:edge` is shipping *today*, not whatever PW pinned. For PW 1.59.1 (chromium 147.0.7727.15), edge already moved to 148.x → drift is unavoidable.

**Why:** Initial plan called for `resolve-aports-ref.sh` to map chromium pkgver → aports commit SHA and pull historical apk. Verified the SHA lookup works (matched 147.0.7727.15 → `c100a537482d8a61016a7f666a6329fbd7e44a27`) but discovered both fetch paths dead-end. Pivoted to "catalog accumulator + drift warning" — see [[project_chromium_drift_warning_pattern]].

**How to apply:** Any future "rewind to old browser version on alpine" idea hits this wall. Don't re-explore from-source builds either — ~12h ninja on hosted runners (>5h ceiling). Either:
1. Drift-warn and ship (current strategy).
2. Build from-source on a self-hosted runner (out of scope).
3. Wait for upstream PW to relax exact-revision matching (not coming).

The resolver script (`resolve-aports-ref.sh`) is kept as diagnostic-only — knows WHICH aports commit but can't fetch the binary.
