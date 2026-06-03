---
name: project-gha-runner-uid-is-1001
description: GitHub-hosted runners execute as UID 1001 — the same UID as the image USER `runner` — so naive `--user $(id -u)` is a no-op on GHA
metadata:
  type: project
---

The GitHub-hosted `ubuntu-latest` runner runs jobs as UID `1001` (user `runner`).
This image's `USER runner` is also UID `1001` (kept identical on purpose, see
[[project-act-bind-host-uid-recipe]]). They coincide.

**Why this matters:** `--user $(id -u):$(id -g)` from inside a TP job is a no-op
on GHA — it just re-asserts 1001:1001, the default. A test that *intends* to
prove the override actually changes the running UID won't, and any assertion
like `test "$owner" != "1001"` will silently pass for the wrong reason.

**How to apply:** TP-level steps that want to exercise UID override must pick a
non-1001 UID:

- **UID 1000** (= `packer`): has a `/etc/passwd` entry → `sudo` works, no
  `nss_wrapper` needed. Use when the test touches `sudo`.
- **UID 5000** (or any unmapped): no passwd entry → `sudo` refuses
  (see [[project-sudo-requires-getpwuid]]); needs `nss_wrapper` for cosmetic
  `whoami`/`$HOME` fix (see [[project-nss-wrapper-scope]]). Use when the test
  is the arbitrary-UID path itself.

The two existing TP steps are split this way: `Bind-mode host-UID recipe`
exercises 1000, `Bind-mode arbitrary-UID via nss_wrapper` exercises 5000.
