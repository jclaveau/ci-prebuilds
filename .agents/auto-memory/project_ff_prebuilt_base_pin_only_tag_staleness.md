---
name: project_ff_prebuilt_base_pin_only_tag_staleness
description: FF prebuilt-base was tagged on PW's FF revision ONLY; a source-only patch to apply-and-build.sh left the rev unchanged so the iter path reused a stale pre-patch base and shipped an unpatched ff-latest. Fix = content-address the base tag on a patch-set hash (PR #81).
metadata:
  type: project
---

`prebuilt-base-ff-<rev>` (heavy FF source+obj/ image, consumed by the iter path
for ~5min incremental rebuilds) was tagged ONLY on PW's pinned Firefox
**revision**. The 2026-07-20 Juggler `location` patch lives in
`firefox/scripts/apply-and-build.sh` (source-only, JS) and doesn't change the
PW rev → `build-firefox`'s auto-select (`docker manifest inspect $BASE_TAG`)
saw the pre-patch base "exists" → chose iter → repackaged pre-patch juggler
with a fresh BuildID. The 2026-07-28 merge (540234e) promoted exactly that:
`ff-latest` BuildID `20260728082355` but its `Page.uncaughtError` schema LACKS
`location` → every consumer still crashes `reading 'url'` on pageerror.

**Tell:** `build-firefox` was 6 min (warm iter), not the ~3h a real recompile
takes. A source-patched build that finishes in minutes = it didn't recompile.

**Fix (PR #81):** content-address the base on the files baked INTO it —
`versions.env` + `apply-and-build.sh` + `fetch-aports.sh` + `fetch-pw-patches.sh`
+ `mozconfig.overlay`, sha256|cut -c1-12 → `prebuilt-base-ff-<rev>-<hash>`.
Producer + consumer compute the same hash from checked-out files (no
coordination). Any patch-set change → new hash → auto-select miss → cold reseed
→ base carries the patch → iter inherits. EXCLUDE `apply-and-build-iter.sh`
(runs at iter time, not baked in). Patch stays single-source (no dup into iter).

**Reseed cost:** ~3h cold, and it's REQUIRED not wasteful — the base was
multi-commit stale across C++/cbindgen build changes (ae60bbb, e5d1907,
f3bd807), not just the JS patch, so an incremental-from-old-base would be
wrong. sccache can't rescue it (cache mounts don't persist across GHA runners —
the very reason the prebuilt-base pattern exists). Reseed is dispatch-only: the
base workflow never fires on push.

**RESOLVED:** PR #81 merged 0baf9cec (2026-07-28). Base reseeded
`prebuilt-base-ff-1522-d175458bf183`; the merge-push run took iter (~10min) →
promote → patched `ff-latest` shipped 12:56Z. Fix verified end-to-end. See
[[project_ff_ship_path_push_and_iter_flake]] for the ship-path + choose_iter
cold-flake follow-ups.

[[project_ff_latest_stale_no_edge_tag]] [[feedback_verify_moving_tag_payload]]
[[feedback_preseed_long_dispatch_pr_branch]] [[project_ff_build_two_pass_cbindgen]]

**Counter-example — a fast round is not always the bug.** WebKit run
32476690483 went wpe-1 4h34m, wpe-2 2h58m, **wpe-3 4 min**. That is the same
shape as the staleness tell above, but it was legitimate: the build converged
in wpe-2 and wpe-3's own log says so —

    Phase 1 already done: .../CMakeCache.txt exists
    Phase 2 already done: .../bin/MiniBrowser exists
    Phase 3 already done: /work/minibrowser-wpe-dist has MiniBrowser
    apply-and-build-port: PORT=WPE all phases satisfied

116 s of the 4 min was the 2.6 GB base pull; the ninja step took 0.1 s. So
check two things before calling a fast round stale: the script's own
phase/"no work" markers, and that `BASE_IMAGE` names the PREVIOUS round's
sha-scoped tag ([[project_multijob_base_image_audit]]) — here
`wk-wpe-2-sha-5719ccb8`, correct.

## 2026-08-25 — the same class, still open for ONE file (fixed, PR #111)

PR #81 content-addressed the base on a patch-set hash, but the file list was
**hand-written in two workflows and omitted `bundle-dist.sh`** — which
`Dockerfile.prebuilt-base` bakes in via `COPY firefox/scripts` and which does
change the artifact. So an edit to it left the hash unchanged, the iter path
reused the pre-edit base, and the build went green having shipped none of it.
A strip pass added there would have shipped nothing.

Fixed in `04af46d`: the set is now DERIVED from the directory in one script,
`playwright/alpine-browsers/firefox/patchset-hash.sh`, that both workflows call.
It lives OUTSIDE `firefox/scripts/` on purpose — a file in there would be baked
in and would hash itself, reseeding a ~4 h build whenever the hash logic
changed. `apply-and-build-iter.sh` stays excluded (iter-time, not baked).

`tests/firefox/test-patchset-hash.sh` (wired via `tests-firefox.yml`, kept out
of `tests-aports.yml` per [[project_firefox_alpine_wip_pipeline]]) pins: editing
`bundle-dist.sh` moves the hash, editing the iter script does not, neither
workflow re-implements the rule inline, and the `COPY` set of
Dockerfile.prebuilt-base is unchanged. Verified red against the old hand-listed
rule and green against the new one.

**The general shape:** a hand-maintained list that must mirror a `COPY <dir>` is
a drift trap. Derive it. [[feedback_complete_set_needs_the_real_artifact]]

