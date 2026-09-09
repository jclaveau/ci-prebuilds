---
name: project_source_tag_probe_pattern
description: uniform CHS_SOURCE_TAG/FF_SOURCE_TAG/WK_SOURCE_TAG build-args + a --jobs-scoped dispatch guard + a same-CPU assertion let any experimental arm get probed via a throwaway consumer image without merging
metadata:
  type: project
---

Three PRs (#160, #161, #162) landed together and compose into one workflow:
probe an unmerged browser-build arm as if it shipped, without a main merge and
without cross-machine noise.

**#160 — uniform `*_SOURCE_TAG` build-args.** `Dockerfile.alpine` gained
`CHS_SOURCE_TAG` / `FF_SOURCE_TAG` / `WK_SOURCE_TAG`, each defaulting to
today's `:<prefix>-${REV}` so nothing changes unless explicitly overridden.
Verified `ARG SRC=${TAG}` resolving inside a `FROM` tag works on this BuildKit
first, via a throwaway `RUN echo ok-arg-in-arg-in-from` build, before wiring
it for real. Renovate's managers (which match `ARG CHS_REV=<digits>`) are
untouched — they don't see the new arg. This generalizes a pattern webkit had
already reinvented informally and badly: a hardcoded experimental-branch
`WK_SOURCE_TAG` override that went STALE (pinned to an older build than the
one that had actually gone 21/21 green), caught only by hand
([[project_wk_premove_build_needs_old_pw]] era). Now any arm's artifact tag
is a build-arg, not a code edit.

**#161 — dispatch-once guard scoped by job prefix.** The guard
([[project_gha_dispatch_once_guard]]) used to refuse a new dispatch if ANY
run was live on the same ref — even an unrelated pipeline (a 24h chromium
chain blocking a webkit dispatch on the same branch). Since those are already
separate pipelines by the workflow's own `concurrency:` key, the guard now
takes `--jobs <prefix>` and only blocks on a live run that owns matching
jobs. Verified by dispatching a webkit build while a chromium chain was still
running on the same ref.

**#162 — same-machine assertion for arm-vs-shipped, not just ours-vs-official.**
"Ours vs official" was already same-job/same-machine by construction
(interleaved in one job). "Experimental arm vs currently-shipped" was NOT —
two separate workflow runs, potentially different CPU models — and had been
rescued by hand twice earlier by manually checking the `libm_fmod` official
fingerprint matched across runs
([[project_perf_probe_ratio_is_cpu_dependent]]). Fix: `image_b`, an optional
second "ours" image interleaved into the SAME job as the official control and
the primary image, so a third arm shares the machine by construction; plus
`assert-one-machine.py`, which reads `runner.cpu` out of every artifact's
metadata and fails the run if a browser's runs disagree on CPU model (checked
per-browser, since browsers legitimately land on different machines across
separate jobs). Mutation-tested: green on real matched artifacts, red when a
second CPU model was deliberately forced onto half the runs.

**How to apply.** To validate an experimental branch before merging: build it
with an explicit `*_SOURCE_TAG`, dispatch via the guard (now safe to run
alongside unrelated pipelines), and read the report's `image_b` column
against the same-job official + shipped legs — `assert-one-machine.py` fails
loud instead of silently comparing apples to a different Xeon.

Used for real on the webkit ThinLTO arm (PR #141): its `WK_SOURCE_TAG` had
gone stale (hardcoded to an older `wk-sha-7210a5d2…` rather than the
`wk-sha-018d5d9f…` build that had actually passed 21/21 conformance) —
replaced with this mechanism, confirmed the correct tag actually appeared in
the build log (not assumed), and measured same-CPU (official `libm_fmod`
fingerprint 68.0ms both legs): `layout` 0.97→0.86, `dom_churn` 1.01→0.91,
`goto_warm` 1.10→1.04, `click_force` 1.25→1.19, `launch` 1.35→1.32,
`eval_rtt` 1.11→1.09, `screenshot` 1.04→1.02 (all improved or held; only
`goto_cold` moved +0.01, inside its 0.12 noise floor).

**Gotcha, 2026-09-08 — an override-built proof image is not the default
path.** A `*_SOURCE_TAG` override proves the artifact behind it is good; it
does NOT prove a plain merge-to-main will ship it, because the Dockerfile's
own default ARG still points at the old tag until something changes the
default (a promote, or another commit). Caught calling `sha-ea0b8149…` (the
override-built WebKit launch-fix image) "the proof image" as if it were
main's build of that commit — it only existed because TP had been dispatched
with an explicit `wk_source_tag` override; the default path still resolved
to the pre-fix producer tag and, separately, never got rebuilt on merge
either ([[project_wk_launch_is_the_loader]],
[[project_wk_promote_gate_holds_the_nightly_bench]]). Always confirm the
DEFAULT (unpinned) build resolves to the fix before calling it shipped.
