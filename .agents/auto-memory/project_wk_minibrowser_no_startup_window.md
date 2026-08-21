---
name: wk-minibrowser-no-startup-window
description: PW passes --no-startup-window for every non-persistent WebKit launch, and MiniBrowser's activate() returns on it before building the settings object — so --features and every webkit_settings_new_with_settings() default reach no PW-created page
metadata:
  type: project
---

`Tools/MiniBrowser/wpe/main.cpp`, with PW's `bootstrap.diff` applied:

```c
static void activate(GApplication* application, ...)
{
    g_application_hold(application);
    if (noStartupWindow)
        return;                    // ← everything below never runs
    ...
    auto* settings = webkit_settings_new_with_settings(
        "enable-developer-extras", TRUE, "enable-media-stream", TRUE, ...);
    if (featureList) { /* --features is applied HERE */ }
```

`playwright-core`'s `webkit.ts` picks exactly one of the two:

```ts
if (isPersistent) webkitArguments.push(`--user-data-dir=${userDataDir}`);
else              webkitArguments.push(`--no-startup-window`);
```

So for an ordinary `webkit.launch()`, `activate()` returns immediately, no
settings object is ever constructed, `persistentWebContext` stays NULL, and PW's
pages come from `createNewPage` → `createWebViewImpl(nullptr, NULL, …)` — a view
built with `"web-context"` and `"is-controlled-by-automation"` and **no
`"settings"` property**. A persistent launch takes the other branch, so
`activate()` runs to completion and `--features` does reach the page it creates.

**Why:** `--features=MockCaptureDevices` looked inert on our build and I inferred
the cause was `createWebViewImpl` dropping `"settings"`. The negative control —
`--features=!MockCaptureDevices` on an arm that *does* show mock devices — left
them present, proving the flag reaches no page on either side and that the real
mechanism is one function earlier. Right symptom, wrong function; a fix built on
the first reading would have patched the wrong place.
See [[feedback_prove_the_lever_is_connected]].

**How to apply:** any "set it at launch" idea for WebKit (features, settings
defaults, MiniBrowser CLI options) is unreachable for normal PW contexts. Levers
that work are per-page ones the inspector applies (`Page.overrideSetting`) or a
source patch inside `createWebViewImpl`. Persistent-context behaviour is NOT a
control for normal-context behaviour — they take different MiniBrowser paths.
