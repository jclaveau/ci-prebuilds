---
name: project_wk_promote_gate_holds_the_nightly_bench
description: RESOLVED 2026-08-26 — the three conformance-webkit blockers were fixed and one dispatch off a COMBINED branch promoted wk-latest to ff0d9b55; GTK-off never blocked the promote
metadata:
  type: project
---

The chain that kept the nightly alpine 3-browser bench red for three nights:

```
3 red conformance-webkit shards
  -> conformance-webkit summary = failure
  -> promote-webkit skipped (it requires conformance success)
  -> wk-2336 / wk-latest stay hand-promoted pre-move builds
  -> the 3-browser alpine image ships a WebKit that cannot serve PW 1.62.1
  -> nightly benchmark-playwright alpine-*-all arms red every night
```

The three blockers and their fixes:

- shard 13 — `permissions.spec.ts camera and microphone` → PR #112, the
  UIProcess never consulted `Browser.grantPermissions`
  ([[project_wk_camera_mic_and_noxserver_dispositioned]]).
- shard 7 — `CacheStorage entry should survive page.reload()` → PR #116, PW's
  bootstrap.diff patches decode and not encode
  ([[project_wk_cachestorage_disk_records_invisible]]).
- shard 12 — `launcher.spec.ts no xserver` → PR #115, the suite now probes the
  artifact for a headed binary instead of assuming one
  ([[feedback_gate_on_measured_capability_not_skip_list]]).

**GTK-off never blocked the promote** — the gate reads only
finalize/smoke/conformance results. An earlier note claiming otherwise was
wrong. Confirmed again 2026-09-08: a fourth, unrelated blocker (conformance
shard 4's runner-image build failing on a disguised network transient, not
GTK) held up the ThinLTO webkit promote the same way — see
[[project_transient_fetch_reads_as_code_fault]].

**What actually shortened it.** Each fix landed on its own branch, and every
in-flight producer run predated the other two, so no single run could ever go
green. Merging all three onto ONE branch and dispatching that
(`build_webkit=true`) validated them together AND promoted, because
`promote-webkit` fires on any dispatch carrying the flag — not only on a push
to main. Run 32958171855: conformance summary success, promote success,
`wk-latest` and `wk-gtk-latest` at revision ff0d9b55. Reach for the combined
branch as soon as two fixes for one gate are in flight separately.

**CORRECTION, 2026-09-08 — that branch-dispatch-promotes behavior is GONE.**
[[project_promote_gates_by_browser]]'s PR #157 unified all three promote
gates to require `github.ref == 'refs/heads/main'` for BOTH the push and the
dispatch path (previously only chromium's apk gate had the branch-dispatch
loophole, and it was a bug there too). Confirmed the hard way with #180 (the
WebKit launch fix): a green branch dispatch with `build_webkit=true`
(run 34189647309, every conformance-webkit shard passing) published ONLY the
sha-scoped producer tag (`wk-sha-0b4bd1d…`) — `wk-2336`/`wk-latest` never
moved. Merging to main then triggered a **push** build, where WebKit is
dispatch-gated OFF, so nothing rebuilt and nothing promoted either. Net: a
fully validated fix can sit unshipped indefinitely unless someone explicitly
dispatches a fresh build on main with `build_webkit=true` (hours, a cold
WebKit round) — or the already-gate-verified branch artifact is retagged
onto the moving tags directly (`docker buildx imagetools create`, ~1 minute,
no rebuild; this bypasses the "must come from main" guard, but the same
commit IS already on main, so the guard's intent — stop unreviewed
experimental branches shipping — is met, not dodged). Retagging is a
published-tag move on two registries (GHCR + Docker Hub), so treat it like
any other irreversible-ish shared-state action: don't do it without an
explicit go, even when it's clearly the right call. Always diff the shipped
tag's `org.opencontainers.image.revision` label against the fixing commit
before calling a producer-side fix live — see
[[project_wk_launch_is_the_loader]].

**RESOLVED 2026-09-08 — retag executed (Option A), user said "A, retag it".**
Mirrored `promote-webkit` by hand: `docker buildx imagetools create` moved
`wk-latest`/`wk-2336`/`wk-26.5` (WPE) and `wk-gtk-latest`/`wk-gtk-2336`/
`wk-gtk-26.5` (GTK) on both GHCR and Docker Hub, 12 tags total, from the
`fac3bb3`/#141 digests to the `wk-sha-0b4bd1d4`/#180 artifact. Recorded
rollback digests first (WPE `sha256:96c33f8a…`, GTK `sha256:849d2320…`).
**GTK was not safe by default assumption** — the source run's
`build-webkit-gtk-1..4` jobs were *skipped*, so promoting it blind would have
shipped the empty-MiniBrowser variant; checked the run behind the *old*
`wk-gtk-latest` first and found GTK skipped there too, so it was a like-for-like
move, not a regression. Independent confirmation the new WPE artifact actually
carries `-DUSE_GSTREAMER_GL=OFF`: compressed size dropped 256→175 MiB, the
libgallium+libLLVM closure leaving matches the mechanism, not just the label.
Then a **separate step** was needed for the consumer: `test-and-publish.yml`'s
promote only fires on `github.event_name == 'push'`, so retagging the producer
alone does nothing for `jclaveau/alpine-dood-playwright:latest` — a real push
touching a TP-watched path was required (PR #192, a doc-only change beside the
`*_SOURCE_TAG` ARGs, since an empty commit is blocked by path filters). #192
merged → TP run resolved the default (unpinned) `wk-2336` tag to the new
digest and republished `latest`. **Confirmed end to end**: `latest` at revision
`d674548`, inline probe reads `launch 0.87` (vs `1.40` that morning on the
stale tag). See [[project_wk_launch_is_the_loader]] for the launch numbers and
[[project_gha_build_duration_not_evidence]] for why the 21-second consumer
rebuild wasn't a sign the retag hadn't taken.
