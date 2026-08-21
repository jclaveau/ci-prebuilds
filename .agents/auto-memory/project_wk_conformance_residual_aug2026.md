---
name: wk-conformance-residual-aug2026
description: Per-cluster verdicts for the WebKit conformance failures left after closePage — what each one actually is, so a clean session does not re-derive them
metadata:
  type: project
---

Baseline: 155 failures → **26** once `closePage` landed (5756 passed, run
32136794311). Then `snapshotRect` (-11) and `setLanguages` (-3) and the
certificate CN (-2). Verdicts on what was left, each traced to evidence:

- **screenshot webp/jpeg (11)** — RESOLVED, see [[project_wk_screenshot_format_ignored]].
- **Accept-Language (3)** — RESOLVED: `setLanguages` only set the pool
  *configuration*, which the already-running network process never re-reads.
- **har security details (2)** — RESOLVED: GLib gives the full RFC 2253 DN, PW
  wants the bare CN; upstream's `subjectSummaryFromDN` backported.
- **camera/microphone (4)** — genuine build gap. NOT skip-list parity: control and
  ours have identical skip sets (8 each; control 8+107=115, ours 4 failed+8+103).
  Not the pref default (`MockCaptureDevicesEnabled` is false at our base *and*
  upstream main), not PW client-side (code search: mock capture is wired only in
  their **macOS** embedder), not our gst env. WebKit registers a
  `mock-device-provider` unconditionally, so the capability exists at our base.
- **modernizr (2)** — the residual key is **`fontdisplay`** (earlier notes saying
  `unicoderange` are stale). We report `true`, PW expects `false`, and no
  preference exists for it — an engine divergence from the base gap.
- **Navigation API same-document (1)** — NOT a protocol or preference gap
  (`NavigationAPIEnabled` is already true for WPE at our base and on main). The
  failure snapshot shows the DOM is **correct** (`paragraph: intercepted:/other`);
  PW's locator reads `""` until timeout, i.e. a stale execution context after a
  same-document navigation.
- **contextmenu order (1)** — we emit `['mousedown','contextmenu']`, never
  `mouseup`. PW's patch touches the WPE context-menu proxy; likely swallowed there.
- **headed / no-XServer (1)** — we shipped an *empty* `minibrowser-gtk`, so a
  headed launch dies instantly instead of printing `cannot open display`, which is
  the string PW greps for (`webkit.ts: doRewriteStartupLog`). Fixed by actually
  building the GTK port. Note that enabling GTK also switches on the headed
  conformance leg via run.sh's capability probe.
- **CacheStorage after reload (1)** — returns null; unexamined.

## Update 2026-08-19 — 8 failures → 6, and two verdicts reversed

Run 32286335559 (`7ba6866`): 17/20 shards green, 6 failures.

**webp: RESOLVED.** `page-screenshot.spec.ts:307 webp screenshots should be
lossless by default` and `elementhandle-screenshot.spec.ts:38 should work with
webp` were ONE bug — `ImageUtilitiesSkia.cpp` sets only `fQuality` and never
`fCompression`, which Skia defaults to `kLossy`. Fixed by
`patch_webp_lossless_encoding` (gate on `fQuality == 100`; quality 80 must stay
lossy, line 310 asserts it). Both green now.

**contextmenu and CacheStorage are REAL divergences, not parity.** Measured
against PW's own shipped `webkit-2336` on 2026-08-19:

```
CONTEXTMENU_EVENTS=["mousedown","contextmenu","mouseup"]
CACHESTORAGE_PERSISTENT_AFTER_RELOAD="payload"
```

Ours gives `["mousedown","contextmenu"]` and `null`. So both fail on OUR build
and pass on upstream's. Two earlier verdicts are retracted:
- yury-s's 2023 "WebKit fires 2 events, consistent with Safari, expected
  behavior" (#26515) is **stale** — WebKit changed since.
- PW #41618's fix PR #41647 was **never merged** (`merged: false`) while the
  test PR #41701 merged 2 seconds before the issue closed — yet upstream passes
  anyway, so the fix turned out to be unnecessary for their build, not skipped.

Neither is a skip candidate. Our base `4d05d732` is NEWER than the `343e13bf`
PW builds from, so both look like regressions introduced upstream between late
April and mid June — or musl. Next step is a source diff across that window;
the runtime pre/post A/B is impossible ([[wk_premove_build_needs_old_pw]]).

**Now inert on the new base** (guards self-disabled, do not credit them):
`patch_page_snapshot_format` (base carries `Page.ImageFormat`) and
`patch_certificate_subject_summary`. Still live: `closePage`, `setLanguages`,
orientation, WebRTC, download-destination, and the new webp block.

Still open and unchanged: camera and microphone x4 (genuine build gap).

**Update 2026-08-21.** Reds down to 6 (17/20 shards). Upstream annotations and
the glibc control now decide each cluster — see
[[project_pw_test_annotations_shape_conformance]]: camera/mic ×4 is a host-gated
`it.skip` we cannot inherit; persistent CacheStorage and contextmenu order are
ours, with the WebKit base exonerated by probing PW's own r2336 and r2349.
WebKit was NOT promoted (jean: hold until the 6 go green); `wk-latest` still
points at the old build, this one is `wk-sha-7ba6866b…` / `wk-edge`.

## Update 2026-08-21 — root causes, all three measured

Three-arm probe (`wk-conformance-residuals-probe.yml`: ours + PW's r2336 + PW's
r2355, one script, one job). **PW main ships r2355 built from `4d05d732`, our
exact base, and our patch pin is newer than PW's last `browser_patches` roll
(2026-07-24)** — so base and patch series are both exonerated and every red is
ours. Six reds: camera/mic ×4, CacheStorage-across-reload, contextmenu order.

- **camera/mic ×4 — delivery, not capability.** `strings` on our own
  `libWPEWebKit` shows `GStreamerMockDeviceProvider`, both mock GStreamer
  sources and every `Mock audio device N`. And with the setting actually
  delivered (a *persistent* launch + `--features=MockCaptureDevices`) our build
  returns all six devices and live audio+video tracks, byte-for-byte what
  upstream returns. So no rebuild helps: the mock centre is compiled, works, and
  is simply never switched on for normal-context pages
  ([[project_wk_minibrowser_no_startup_window]]). Runtime symptom is
  `Audio capture was requested but no device was found amongst 0 devices`, a
  line upstream never prints. **Still open: what turns it on upstream.** Not the
  client (the shipped `playwright-core@1.62.1` bundle sends exactly seven
  `Page.overrideSetting` calls, none of them this one), not `bootstrap.diff`, not
  a launch arg, and not the compiled default (PW's own binary prints
  `- MockCaptureDevices` too).
- **CacheStorage — `put()` is a silent no-op.** After `await cache.put()`
  resolves, `cache.keys()` is `[]` on ours and `["/meta"]` upstream, and 3s of
  polling never fills it. Nothing is stored, so nothing is "lost across the
  reload" — the reload and the disk were both red herrings: our persistent
  profile tree is structurally identical to upstream's (same `Version 16/salt`,
  `cacheslist`, `origin`, `salt`; neither writes a record file). The same code
  works in an ephemeral context.
- **contextmenu — WebKit ACKs the release and drops it.** `pw:protocol` shows
  the driver sending `{"id":95,"type":"up","button":"right"}`, the browser
  answering `{"result":{}}`, and no DOM `mouseup` ever reaching the page. Not
  the driver, not transport. A press and release separated by 500ms delivers the
  full correct `["mousedown","contextmenu","mouseup"]`, so it is a race, not a
  missing capability. `WebContextMenuProxyWPE::showContextMenuWithItems` is
  `notImplemented()` on WPE (menu never shows *or dismisses*) — but that is
  identical upstream, so it is not the cause on its own.

**Retracted leads, do not re-raise:** `ENABLE_CONTEXT_MENUS` (globally
`PRIVATE ON`, already on in our build), the persistent `WebsiteDataStore` path
(tree matches upstream), WPEPlatform / `DEVELOPER_MODE` (PW's own r2336 ships
libwpe+fdo, the same legacy path we build), and patching the preference default
(PW's binary has the same default).

**Rebuild economics:** a WebKit rebuild is ~10h, so any source patches these
need get batched into ONE build, never one per cluster.

**Strip A/B — REFUTED 2026-08-21, do not re-raise.** The consumer strip
(`strip-bundled-libs.sh`) removes libwpe, libWPEBackend-fdo and glib/gio, so we
run against apk libs while WebKit was compiled against the bundled ones — a real
divergence upstream does not have, and a tempting explanation for all three
reds. It is not the cause. Restoring the whole artifact over the stripped runner
(`COPY --from=<ref> /webkit /ms-playwright/webkit-<rev>`, run 32472479248) left
every cluster byte-identical: contextmenu `["mousedown","contextmenu"]`,
`cachestorage-cache-index` `[]`, `capture-device-list` `[]`. Verified rather than
assumed — the restored image carries the 2 bundled wpe libs and `ldd` resolves
`libWPEBackend-fdo-1.0.so.1` to the bundled copy, not `/usr/lib`.

Note in passing (a real inconsistency, just not this bug): we build libwpe from
master and patch `WPEBackend-fdo`'s `fdo.cpp` *because* Alpine's apk builds hit a
musl static-init wall, then strip exactly those two so the apk versions load —
leaving the `__attribute__((constructor))` fix inert in every runnable image.
The libwpe clone is also `--depth=1` off master with no pin, so the build-time
version is not reproducible.

**Client parity confirmed on the wire, not inferred.** Both arms' `pw:protocol`
logs carry the identical seven `Page.overrideSetting` calls — FullScreenEnabled,
NotificationsEnabled, PointerLockEnabled, InputTypeMonth/WeekEnabled,
FixedBackgroundsPaintRelativeToDocument, PushAPIEnabled — and neither ever sends
`MockCaptureDevicesEnabled`. So upstream's mock centre is on without the
inspector override, which closes the last client-side explanation by observation
rather than by reading their bundle.

## Update 2026-08-21 (run 32473728973) — three more causes eliminated

- **contextmenu is NOT timing.** A press/release sweep at 0/25/50/100/200/400ms
  passes at EVERY delay, 0ms included, giving the full
  `["mousedown","contextmenu","mouseup"]`. The discriminator is not the gap but
  how the frames are sent: `page.mouse.down()`+`up()` are separately awaited and
  each round-trips, while `click()` PIPELINES move/down/up before any response —
  the failing wire shows ids 93/94/95 all sent at `09:48:51.920` and all ACKed at
  `.923`. So our build drops the release only when input events are pipelined.
  Retract the earlier "race / 500ms threshold" reading.
- **Upstream's mock centre is NOT preference-driven.** With
  `--features=!MockCaptureDevices` in the one launch shape where the flag
  reaches the page, upstream STILL returns live audio+video tracks while ours
  returns `OverconstrainedError`. Ours responds to the preference (the positive
  flag works); upstream ignores it because something else already enabled the
  centre. Every preference-based explanation for upstream is therefore dead —
  including the caller list derived from GitHub code search, which is
  known-incomplete and is the likeliest place the real path is hiding.
- **CacheStorage is not the filesystem.** Same probe with the profile on a
  tmpfs instead of the container's overlayfs fails identically
  (`cache-index` `[]`), and `df` inside the container reports 82 GB available,
  so a free-space-derived quota of zero is out too.

## Update 2026-08-21 (run 32474867037) — two corrections, both from better probes

- **contextmenu: pipelining CONFIRMED, and narrowed.** Three dispatch shapes,
  fresh context each (no order effect): `locator-click` FAIL,
  `awaited-manual` PASS, `pipelined-manual` **FAIL** — identical protocol
  frames, differing only in whether the release waits for the press to be
  answered. Upstream passes all three. But `mouseup-on-left-click` (also a
  pipelining locator click) PASSES, so pipelining alone is not fatal: the
  release is dropped only when a contextmenu event sits between press and
  release AND the release arrives unacknowledged. Retracts the earlier
  "timing / 500ms threshold" reading, which came from a sweep confounded by
  running every iteration after the failed click on one page.
- **CacheStorage: the record DOES reach disk — retract "put() stores
  nothing".** With the estimate call guarded (it had been throwing and killing
  the rest of the probe on our arm), the profile shows
  `CacheStorage/<hash>/Version 16/Records/<hash>/<uuid>/<hash>` on ours exactly
  as upstream. Yet `cache.keys()` is `[]` and `match()` is null in the same
  document. So the write lands and the LIVE READ PATH cannot see it — an
  index/read-back fault in the network process, not a write fault. (The extra
  files on our side, 31 vs 27, are `WebKitCache/Version 17/Records/.../Resource`
  — the HTTP cache, incidental.)

## Update 2026-08-21 — source read at 4d05d732 (sparse clone, 174 MB)

**contextmenu: ROOT CAUSE.** `WebPageProxy::showContextMenu()`
(`UIProcess/WebPageProxy.cpp:11981`) calls `discardQueuedMouseEvents()`, with
upstream's own comment: *"Discard any enqueued mouse events that have been
delivered to the UIProcess whilst the WebProcess is still processing the
MouseDown event that triggered this ShowContextMenu message. This can happen if
we take too long to enter the nested runloop."* So the path is explicitly racy,
and it explains every measurement: pipelined release is already queued →
discarded; awaited release is sent after the press is answered → not yet queued
→ survives; left click has no context menu → no discard. PW does NOT patch this
(their only `discardQueuedMouseEvents` hunk is the drag path at 4285), so both
builds run it and we simply lose the race — most plausibly a slower musl
mousedown→ShowContextMenu round trip.
Just above it sits an escape hatch we do not qualify for:
```cpp
if (RefPtr automationSession = configuration().processPool().automationSession()) {
    if (m_controlledByAutomation && automationSession->isSimulatingUserInteraction())
        return;   // pretend to show and dismiss — no discard
}
```
PW drives via the inspector, not `WebAutomationSession`, so `automationSession()`
is null and we fall through. **Candidate fix (rebuild): skip the discard when
`m_controlledByAutomation` is set** — synthetic input has no stray user events
to discard. Plausibly upstreamable to PW.

**camera: RETRACT "not preference-driven".** The caller list is complete (the
clone confirms code search): only `SettingsBase`, `GPUProcess` and
`syncWithWebCorePrefs`. But the mock centre is a process-global that LATCHES —
`syncWithWebCorePrefs` returns early when the page's value already equals the
global — so `--features=!MockCaptureDevices` on one page proves nothing about
whether the preference drives it. The open question is which page turns it on
upstream, and when.

**CacheStorage: lead, unproven.** `CacheStorageDiskStore::readAllRecordInfos`
drops a record silently on BOTH a failed read and a failed decode (two bare
`continue`s), and `SafeFileData::read` mmaps first via
`FileSystem::isSafeToUseMemoryMapForPath` / `makeSafeToUseMemoryMapForPath` —
a plausible musl/overlayfs failure point. Its `RELEASE_LOG_ERROR` never appeared
in our captured stderr, so this is a lead and not a finding; the NetworkProcess
log is the thing still missing.

Sparse clone kept at `/home/jean/dev/.webkit-grep` (Source/WebKit + the
mediastream/mock/cache/page dirs at 4d05d732) for the next round.

## Patches in flight (branch `fix/webkit-residual-patches`, build 32476690483)

Three `patch_*` functions in `webkit/scripts/prep-source.sh`, each asserting it
applied so a bad anchor fails in source-prep rather than hours into compiling:

- `patch_keep_synthetic_mouse_events` — **FIX**. Guards
  `discardQueuedMouseEvents()` in `showContextMenu` with
  `if (!m_controlledByAutomation)`. Witness: right-click event order in
  `webkit/smoke/launch.cjs`, red on the current artifact.
- `patch_mock_capture_for_automation` — **FIX**. `mockCaptureDevicesEnabled()`
  returns true for automation-controlled pages, and `syncWithWebCorePrefs` now
  calls that accessor instead of duplicating the expression. Witness:
  `getUserMedia` returning audio+video in smoke. NOTE it is user-visible for
  every consumer driving our WebKit — mock devices appear where none did — which
  is upstream parity, not divergence, but it IS a behaviour change.
- `patch_log_dropped_cache_records` — **DIAGNOSTIC, not a fix**. `RELEASE_LOG`
  at both silent `continue`s in `readAllRecordInfosInternal`, tagged
  `ALPINE-DIAG`. No witness, because it asserts nothing; do NOT read a green
  build as validating it. Grep the smoke/conformance logs for `ALPINE-DIAG` to
  learn whether the record is unreadable or undecodable.

PRs: #97 (WPE clone pins, open question tags-vs-commits), #98 (contextmenu fix).
`fix/webkit-residual-patches` is stacked on #98 and has NO PR yet.

