---
name: alpine-apk-bug-draft
description: Pre-written Alpine community/chromium apk bug report. File at gitlab.alpinelinux.org/alpine/aports/-/issues once chromium-from-source build confirms the UA-stylesheet fix.
metadata:
  type: project
---

# Title

`chromium-headless-shell`: broken UA stylesheet — vanilla `<div>` renders as `display:inline`, form controls as `appearance:none`

# Body

The `chromium-headless-shell` subpackage from `community/chromium` ships
without the UA-stylesheet resources, so the browser does not apply
HTML's default block/inline / form-control rendering rules. This makes
the binary unusable as a drop-in replacement for upstream chrome-headless-shell
in test automation (Playwright, Puppeteer, etc.).

## Reproduction

```sh
docker run --rm -it alpine:edge sh -c '
  apk add --no-cache chromium-chromedriver chromium-headless &&
  /usr/bin/chrome-headless-shell --no-sandbox --headless --dump-dom \
    "data:text/html,<!DOCTYPE html><div id=t style=\"width:1px;height:1px\"></div>" \
    2>/dev/null'
```

In our PW conformance harness this manifests as ~150 PW page-suite
test failures with the symptom `element is not visible` AFTER a
locator resolves the element:

```
- locator resolved to <input id="checkbox" type="checkbox"/>
- attempting click action
  2 × waiting for element to be visible, enabled and stable
    - element is not visible
  - retrying click action
  ...
Test timeout of 30000ms exceeded.
```

## Confirmed via local probe

`docker run` against the apk-fast-path build at PW SDK + minimal launch
(no PW config patching):

- `<div>` (no styles): `getComputedStyle(el).display` → `"inline"` (expected `"block"`)
- `<p>`, `<h1>`, `<h2>`, `<article>`, `<section>` — same
- `<input type="checkbox">`: computed `appearance: "none"` (expected `"auto"`)
- `<input type="checkbox">` boundingBox: `{x:0,y:0,width:0,height:0}` (expected `{x:0,y:0,width:13,height:13}`)
- Adding inline style `appearance: auto !important` restores the 13×13
  native checkbox.

## Artifact filesystem

The `chrome-headless-shell-linux64/` directory in the apk contains:

```
chrome-headless-shell      (the binary)
headless_lib_data.pak      745 KB
v8_context_snapshot.bin    740 KB
ld-musl-x86_64.so.1
lib*.so.*                  (a few dozen .so deps)
locales/
vk_swiftshader_icd.json
```

There is **no `resources/` directory** at all. Upstream chrome-headless-shell
distributions include the UA stylesheet (in `chrome_100_percent.pak` or a
sibling resource pak) which is what makes `<div>` render as a block element.
`headless_lib_data.pak` is 745 KB; upstream chromium's `chrome_100_percent.pak`
is ~7 MB.

## Reference

A from-source chromium-headless-shell build against the same Alpine
sysroot **with the standard resource pak generation pipeline enabled**
does NOT exhibit the bug (`<div>` renders as block, `<input>`-controls
render at the native UA size). Linked CI run [TODO: paste run URL from
build-chromium-headless-shell-from-source step once green].

So the regression is in the apk packaging / build flags, not in chromium
upstream itself.

## Impact

Anyone using `chromium-chromedriver` or `chromium-headless` from
`community/chromium` for browser automation against vanilla HTML
elements (most real-world test suites) will hit "element is not visible"
failures that look like timing bugs but are layout bugs.

## Suggested fix

Either:
1. Ship the missing `resources/` directory + the standard resource pak
   files alongside `chrome-headless-shell` in the subpackage definition.
2. Re-include the UA stylesheet content into `headless_lib_data.pak`
   if it was dropped by a build flag.

Happy to test a patch.

---

# Action checklist before filing

- [ ] chromium-from-source build green in our CI (run TBD)
- [ ] Smoke against from-source artifact confirms `<div>` is `block`
- [ ] Capture run URL into the "Reference" section above
- [ ] Resolve PR #76 conflict + merge so the public artifact tag is reachable
- [ ] File at https://gitlab.alpinelinux.org/alpine/aports/-/issues
- [ ] Tag `Tom Brinkman <tom@gitlab.alpinelinux.org>` (current `community/chromium` maintainer; verify before pinging)
