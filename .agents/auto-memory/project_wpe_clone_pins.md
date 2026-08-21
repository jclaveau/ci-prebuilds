---
name: wpe-clone-pins
description: libwpe and WPEBackend-fdo are pinned to master COMMITS, not tags — their tags sit on a release branch diverged from master and are exactly the apk versions whose musl static-init wall sent us to master
metadata:
  type: project
---

`Dockerfile.source-prep` builds both from pinned commits:

```
libwpe          445a0b5579aba7eca619973ca476bb5291a85cf5   (master, 2025-09-23)
WPEBackend-fdo  84492327673fa0dedfa4fa0ab9488bed1763a5a8   (master, 2025-12-20)
```

**A tag pin is the wrong move here, and looks right until you check:**

```
libwpe master...1.16.3   status=diverged  ahead=8  behind=7
apk ships libwpe 1.16.3 and libwpebackend-fdo 1.16.1
```

Those apk versions are precisely the ones whose musl ABI/static-init wall is why
we build from source at all — so "pin to the newest tag" would silently swap in
the code we rejected. The tags live on a release branch; master is a different
line of development.

**Why pinned at all:** both were `git clone --depth=1` of master, so the
libraries WebKit builds against changed whenever upstream moved, and "which
libwpe are we running" was unanswerable mid-investigation. The fdo pin matters
more on its own: we replace `src/fdo.cpp` wholesale, so an upstream move can
desync our file from the `interfaces.h` it includes — surfacing as a compile
error hours into a build.

**Open, not decided** (PR #97 "build(webkit): pin the libwpe and WPEBackend-fdo
clones"): whether to track releases instead, which would mean re-testing the
musl static-init issue. Also still open and separate: the consumer strip removes
both libs so the apk copies load and our `__attribute__((constructor))` fix is
inert at runtime — a real inconsistency, measured NOT to cause the conformance
reds ([[project_wk_conformance_residual_aug2026]]).
