---
name: feedback_say_per_gap_microbench_not_sweep
description: call candidates/gapsweep (run-sweep.sh + gapsweep.c, ns/call per exponent gap per fmod build) a "per-gap microbench", not a "sweep"
metadata:
  type: feedback
---

In talk and reports, name the fmod gapsweep run (`webkit/fastfmod/candidates/gapsweep/`,
dispatched through wk-lag-diagnostics.yml) the **per-gap microbench**. Never "sweep".
The kernel bench (WebKit's libm_fmod loop, ms) stays the "kernel bench".

**Why:** jean 2026-10-09 asked "what do you call a sweep here?" because the word hid
what was measured. Then: "call it a per-gap microbench for now".
**How to apply:** use it in prose, tables and commit messages. The file and dir names
(`gapsweep`, `run-sweep.sh`) stay until jean asks for a rename ("for now").
See [[project_fmod_everywhere_preload_vs_patched_musl]].
