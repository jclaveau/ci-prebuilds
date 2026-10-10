---
name: project_llvmprofdata_forward_gate_and_alpine_path
description: llvm-profdata refuses to read a profile written by a NEWER llvm's instrumentation runtime ("unsupported instrumentation profile format version") — forward-only version gate; Alpine's llvm23 apk package does not put its binaries on PATH, call /usr/lib/llvm23/bin/llvm-profdata explicitly
metadata:
  type: project
---

Hit while verifying the FF PGO corpus-append experiment
([[project_ff_pgo_corpus_append_experiment]]): pulling `merged.profdata` out
of a `ff-pgo-profile-sha-*` image (written by the clang23 toolchain's
instrumentation runtime) and reading it with the box's `llvm-profdata-20`
failed with `error: … unsupported instrumentation profile format version`.
The gate is forward-only — an older `llvm-profdata` cannot read a newer
runtime's profile, even though the profile itself is IR-level and toolchain
version isn't otherwise a compatibility axis you'd expect to matter.

**Fix:** read the profile with a matching-or-newer `llvm-profdata`. Alpine's
`llvm23` apk package installs to `/usr/lib/llvm23/bin/` but does **not**
symlink its binaries onto PATH the way `llvm22`'s did — `apk add llvm23`
inside `alpine:edge` leaves `llvm-profdata: not found` until you call the
absolute path `/usr/lib/llvm23/bin/llvm-profdata` directly.

**How to apply:** whenever comparing `.profdata`/`.profraw` artifacts across
a toolchain bump (or reading one built by CI locally), match the reader's
llvm major to the writer's, and don't assume the Alpine package puts the
binary on PATH — check `/usr/lib/llvm<N>/bin/` first.
