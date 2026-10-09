---
name: project_wk_o3_arm_dead_cflags_dead_code
description: WebKit is already built -O3 via cmake's Release default; apply-and-build-port.sh's CFLAGS=-O2 default is dead code, an -O3 arm would be a no-op
metadata:
  type: project
---

Before dispatching a beyond-parity "-O3" experiment arm for WebKit, read the
actual flag flow: `cmake-flags.overlay` sets `-DCMAKE_BUILD_TYPE=Release`,
which makes cmake append its own `CMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG` **last**
— nothing in WebKit's own cmake (WebKitCompilerFlags / OptionsCommon /
OptionsWPE) overrides that. `apply-and-build-port.sh:78`'s
`: "${CFLAGS:=-O2 -pipe -g1}"` sets an env CFLAGS, but the overlay's own
`-DCMAKE_C_FLAGS=...` on the cmake command line replaces env CFLAGS entirely
— so that default is dead code and WebKit has been built at -O3 all along.

Caught before spending a cold ~4h dispatch on it (verify an A/B varied the
variable, before running it, not after). Dropped from the beyond-parity lever
list; the CFLAGS line in apply-and-build-port.sh:78 is a cleanup candidate
(delete, or fix if the intent was ever to actually apply it).

**How to apply:** any future "-Ox" experiment on WebKit must first confirm
what `CMAKE_BUILD_TYPE` and `-DCMAKE_C_FLAGS` actually resolve to for that
target — cmake flag ordering means the last `-O` flag on the command line
wins, and `Release` puts one there for free.
