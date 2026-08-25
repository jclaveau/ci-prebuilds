---
name: project_wk_camera_mic_and_noxserver_dispositioned
description: WebKit camera/mic ROOT-CAUSED — ed83438 worked but was half a fix; the UIProcess auto-grant needs MockCaptureDevicesPromptEnabled=false too (it defaults true), fixed in 525f238/PR #112; includes a ~30s local repro that replaces the multi-hour build cycle
metadata:
  type: project
---

Run 32786226038 (`wk-sha-587a8de`): 6 failures / 20 shards, contextmenu FIXED.

**`pw_run.sh` picks the port by headless-ness — this is the key fact:**

    MINIBROWSER_FOLDER="minibrowser-gtk";          # default
    if [[ "$*" == *--headless* ]]; then
      MINIBROWSER_FOLDER="minibrowser-wpe";
    fi

**no-xserver (`launcher.spec.ts:55`) — structurally unpassable, PROVEN.** It
launches HEADED, so it takes the GTK path, and a WPE-only build has no
`minibrowser-gtk/MiniBrowser`. It asserts the message "Looks like you launched
a headed browser without having a XServer running" but gets
`pw_run.sh: line 72: …/minibrowser-gtk/MiniBrowser: No such file or directory`.
Only shipping the GTK port can make it pass. NOTE: the headed-leg gate in
`conformance/run.sh` (300f1b7) does NOT cover this — that gate skips the headed
LEG (`headful.spec.ts`), while this is a test inside the standard suite that
launches headed itself. Necessary but insufficient.

**camera/mic ×4 (`permissions.spec.ts:349`) — narrowed, not closed.**
- Fails with `{"error":"OverconstrainedError"}`, NOT NotAllowedError, so
  `grantPermissions` works and `getUserMedia` runs — there is simply no device.
- The control PASSES: `conformance-ubuntu-webkit` runs the same tests
  (skip-list-ubuntu/webkit has NO camera/mic entries, 8 title skips total), so
  official WebKit satisfies them on a machine with no camera either.
- **Refuted: mock capture devices.** `MockCaptureDevicesEnabled` exists in PW's
  `Page.Setting` enum but PW's server code never SENDS it — it is only declared
  in the generated `protocol.d.ts`.
- **Refuted: the GTK/WPE split.** `webkit_settings_set_enable_media_stream(…,
  TRUE)` appears only in `Tools/MiniBrowser/gtk/main.c`, but these tests are
  headless so ours AND official both run the WPE MiniBrowser.
- ENABLE_MEDIA_STREAM is ON for us: `prep-source.sh` forces ENABLE_WEB_RTC ON
  for WPE and MEDIA_STREAM is WEBKIT_OPTION_DEPEND'd on it — and
  OverconstrainedError proves getUserMedia exists.

**Next decisive test:** run `permissions.spec.ts:349` locally against the
artifact with GST_DEBUG on and read what device enumeration returns. Remaining
candidates are GStreamer element availability in our alpine runner versus the
MCR ubuntu image, and musl-side differences in WebKit's capture backend
([[project_wk_media_gst_registry_env]] — installed ≠ discovered has fooled this
repo once already). [[project_wk_conformance_residual_aug2026]]

**2026-08-25 — camera/mic ROOT-CAUSED and fixed (ed83438, run 32807102783).**
The probe, run against our artifact and mcr…:v1.62.1-noble with
`GST_DEBUG_FILE` (PW discards the web process's stderr, so plain `GST_DEBUG`
shows nothing):

    ours      GStreamerMockDeviceProvider.cpp:53  "Mock capture sources are
                                                   disabled, returning empty
                                                   device list"
    official  GStreamerMockDeviceProvider.cpp:57  "Probing" -> 6 mock devices

Opposite branches of one `if`, so the gate is exactly
`MockRealtimeMediaSourceCenter::mockRealtimeMediaSourceCenterEnabled()`, whose
only UIProcess caller reads `preferences->mockCaptureDevicesEnabled()`.
Official's devices are WebKit's own mocks — labels read "Mock audio device 1"
… "Mock video device 2" once permission is granted.

Excluded before touching source:
- **not the build** — `grep -a` on both `libWPEWebKit`: provider, device names
  and both log strings present exactly once on EACH side;
- **not our base move** — the pref defaults false at ours (4d05d732) AND PW's
  (6b34ac51);
- **not PW** — a live protocol trace shows PW sends seven `Page.overrideSetting`
  values and NOT `MockCaptureDevicesEnabled`; no revision of bootstrap.diff
  touches mock capture; the GLib `enable-mock-capture-devices` property just
  inherits `FEATURE_DEFAULT`;
- **not GStreamer discovery** — ~250 plugins and no `GST_*` env on either side.

Official must set it in a build recipe **Playwright no longer publishes** —
their `browser_patches/*/build.sh` 404s on every tag. So `prep-source.sh`'s
`patch_mock_capture_devices_default` sets it, scoped to the WebKit layer.

**Also proven here: `wk-2336` still hangs.** The consumer image
`alpine-dood-playwright:sha-587a8de` never returns from `newPage` under PW
1.62.1 — issue #100 reproduced locally, which is why that perf-probe skip must
stay until promote moves `wk-2336`.

**2026-08-25 — SUPERSEDED BELOW. ed83438 DID work; it was half a fix. The
"obvious follow-up" (flipping WebCore) is still WRONG, for the reason given.**

Run 32807102783 built from `fix/webkit-mock-capture-devices`, conformance ran
against `wk-gtk-sha-ed83438` (verified from the job log, so the right image),
the patch is confirmed applied in the build log — and the three camera/mic
tests still fail with `tracks: []`. WebKit residual is now 5: camera/mic x3,
no-xserver, CacheStorage.

The pref block at our pinned base `4d05d732` has THREE default layers:

```yaml
MockCaptureDevicesEnabled:
  webcoreOnChange: mockCaptureDevicesEnabledChanged
  defaultValue:
    WebKitLegacy: { default: false }
    WebKit:  { "PLATFORM(IOS_FAMILY_SIMULATOR)": true, default: false }
    WebCore: { default: false }
```

ed83438 flipped only `WebKit`. The tempting follow-up — flip `WebCore` too —
is **actively harmful**, and I had it written and tested before catching it:

- `SettingsBase::mockCaptureDevicesEnabledChanged()` is the ONLY thing calling
  `MockRealtimeMediaSourceCenter::setMockRealtimeMediaSourceCenterEnabled()` in
  the WebProcess, and the generated setter fires it **only when the value
  changes**.
- WebCore's default being `false` is precisely WHAT MAKES IT FIRE when the store
  pushes `true`. Set both to `true` and the write is a no-op, the hook never
  runs, and the mock centre stays disabled.

So the chain WebKit-default -> `WebPreferencesStore::defaults()` ->
`WebPage::updatePreferences` -> `Settings::setMockCaptureDevicesEnabled(true)`
-> onChange **should already work**, which means the real failure is elsewhere.
Also excluded this round: the GLib layer (`WebKitSettings.cpp` uses
`FEATURE_DEFAULT(MockCaptureDevicesEnabled)`, so it inherits the generated
default rather than overriding it), and `ENABLE(MEDIA_STREAM)` being off
(prep-source.sh forces `ENABLE_WEB_RTC ON` and MEDIA_STREAM is
`WEBKIT_OPTION_DEPEND`'d on it).

**Source reading has hit its limit — stop theorising and instrument.** Next
instrument is runtime, not another hypothesis: pull `wk-gtk-sha-ed83438`, call
`navigator.mediaDevices.enumerateDevices()`, and get WebKit/GStreamer logs out
of the child process with `GST_DEBUG_FILE` (the parent discards child stderr).
The open question a log answers and source cannot: whether capture runs in the
GPUProcess on WPE (`captureVideoInGPUProcessEnabled`), in which case the
WebProcess mock centre is irrelevant and the gate is
`GPUProcessProxy::setUseMockCaptureDevices`.
[[feedback_instrument_before_theorising]], [[feedback_child_process_logs_via_file]]


**2026-08-25 (later) — ROOT CAUSE FOUND. Two prefs, not one.**

The UIProcess auto-grant is gated on BOTH:

```cpp
if (preferences->mockCaptureDevicesEnabled()
    && !preferences->mockCaptureDevicesPromptEnabled())
    grantRequest(...);   // UserMediaPermissionRequestManagerProxy.cpp:782
```

`MockCaptureDevicesPromptEnabled` **defaults `true`** at our base, so `!true`
killed the condition regardless of the first pref, and every request fell to
`requestSystemValidation()` — nothing to validate against in a container →
`NotAllowedError`. Fixed in 525f238 (PR #112): flip it in the same
`prep-source.sh` pass. Safe outright — single `WebKit:` default layer,
`webcoreBinding: none`, no `webcoreOnChange`, so no transition carries it.
`MockCaptureDevicesEnabled` keeps `WebCore: false` for the onChange reason above.

**The ~30-second local repro — this is the reusable part.** It replaced a
multi-hour build per hypothesis:

- probe image = consumer `alpine-dood-playwright` + `npm i playwright-core@1.62.1`,
  with `/ms-playwright/webkit-<REV>/minibrowser-wpe` replaced by the producer
  image's whole `/webkit/minibrowser-wpe`;
- run with the runner's REAL env or the result is fiction:
  `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` + `WEBKIT_FORCE_SANDBOX=0` (the
  old `WEBKIT_DISABLE_SANDBOX=1` spelling is the known typo and leaves bwrap
  LIVE — with it, `enumerateDevices()` CRASHES the page), `seccomp`+`apparmor`
  unconfined, `SYS_ADMIN`+`NET_ADMIN`, and the three `GST_*` vars from
  build-runner.sh ([[project_wk_media_gst_registry_env]]);
- `navigator.mediaDevices` is undefined on `about:blank` — serve over
  `http://localhost` or you measure the secure-context rule, not the bug;
- mirror the test exactly: `context.grantPermissions([...], { origin: PREFIX })`.
- control: `mcr.microsoft.com/playwright:v1.62.1-noble` + the same script.

**Reading the evidence:**

- `GST_DEBUG_FILE` shows the branch — `GStreamerMockDeviceProvider.cpp:57
  "Probing"` (good) vs `:53 "disabled"`. Post-ed83438 we take :57 and create all
  six mocks, which is what proves ed83438 worked.
- `enumerateDevices()` returning `audioinput|` + `videoinput|` with EMPTY labels
  means the UIProcess HAS devices but no grant. In a container with no
  `/dev/video*` and no `/dev/snd` those can only be mocks — that single
  observation separates "no devices" from "not granted".
- `WEBKIT_DEBUG=all` gets you nothing: the `ALWAYS_LOG(... "action: ")` in
  UserMediaPermissionRequestManagerProxy is compiled out of a Release build.
- The `is-controlled-by-automation ... falling back to default session` CRITICAL
  is NOISE — official logs it identically and passes
  ([[feedback_benign_loud_vs_fatal_log]]).
