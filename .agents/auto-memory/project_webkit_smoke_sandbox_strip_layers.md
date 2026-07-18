---
name: project-webkit-smoke-sandbox-strip-layers
description: WebKit's bwrap sandbox needs progressive Docker permission strip to launch in CI; final layer is WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
metadata:
  type: project
---

WebKit's WPE port spawns `WPENetworkProcess`/`WPEWebProcess` via bubblewrap. Under Docker default settings, each sandbox primitive fails with a distinct error; the smoke step needs every permission stripped to get the renderer subprocess up.

The progression (each row is what unblocks the error from the previous):

| Error in smoke log | Add to docker run |
|---|---|
| `bwrap: Creating new namespace failed: Operation not permitted` | `--security-opt seccomp=unconfined --security-opt apparmor=unconfined --cap-add SYS_ADMIN` |
| `bwrap: loopback: Failed RTM_NEWADDR: No child process` | `--cap-add NET_ADMIN` |
| `bwrap: execvp /opt/playwright/webkit-2287/minibrowser-wpe/WPEWebProcess: No such file or directory` (file IS present at flat layout!) | `-e WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` |

**Why the execvp error fires despite the file existing:** WebKit's `BubblewrapLauncher.cpp` bind-mounts a hardcoded list into the sandbox root (`/usr`, `/lib`, `/etc`, autodetected exec dir). Our custom `/opt/playwright/webkit-2287/minibrowser-wpe/` path is not auto-mounted; bwrap chroot can't see the aux process binary even though `ls` on the host sees it. `WEBKIT_FORCE_SANDBOX=0` did NOT honor this in our build (env tested empty-effect); `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` did.

Tier-2 docker run final shape:
```bash
docker run --rm \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  --cap-add SYS_ADMIN \
  --cap-add NET_ADMIN \
  -e WEBKIT_FORCE_SANDBOX=0 \
  -e WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
  -e PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1 \
  ...
```

**Env-var spelling is load-bearing — CONFORMANCE had a typo.** The disable var
is ONLY `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` (WebKit ignores any short
`WEBKIT_DISABLE_SANDBOX`; PW-core doesn't read it either). pw-conformance.yml
shipped the misspelled short form for months → bwrap stayed LIVE in conformance
(the SYS_ADMIN cap it grants proves bwrap runs), silently breaking WK file-input
+ download tests (the sandbox didn't mount PW's host tmp dirs). Fixed 2026-07-18.
See [[wk-fileinput-download-musl-gaps]]. Any WK file-I/O oddity → confirm bwrap
is actually disabled (correct var) before blaming musl/WebKit source.

**How to apply:** the strip order matches the smoke log error sequence — peel one layer per iter, don't skip ahead, because each error masks the next. If GHA runner config changes (e.g. AppArmor profile tightens), the seccomp/apparmor strip may itself stop working — at that point `-DENABLE_BUBBLEWRAP_SANDBOX=OFF` in cmake-flags.overlay (rebuild WebKit, ~9h cold) bakes the sandbox out entirely.

**PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1** is unrelated but in the same docker run: PW's `validateDependenciesLinux` calls `/sbin/ldconfig -p`; musl rejects `-p` with "Illegal option" but exits 0 with empty stdout. PW then flags ALL `dlOpenLibraries` (hardcoded `["libGLESv2.so.2", "libx264.so"]` for WebKit) as missing → false "apt-get install libgles2 gstreamer1.0-libav" suggestion. Upstream PW bug on Alpine/musl; the env skips the validator.

Related: [[project-webkit-libwpe-bss-explicit-ctor]] (the wall before this), [[project-webkit-alpine-branch-c]] (parent), [[project-pw-upstream-juggler-handshake-hang]] (FF #60 — the land-disabled fallback if a wall is unbreakable).
