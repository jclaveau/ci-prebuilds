#!/usr/bin/env node
/*
 * All six WebKit conformance reds that survive on Alpine, in one probe:
 *
 *   tests/page/page-click.spec.ts:1203
 *     'should fire contextmenu event on right click in correct order'
 *   tests/library/defaultbrowsercontext-2.spec.ts:285
 *     'CacheStorage entry should survive page.reload()'
 *   tests/library/permissions.spec.ts:349,364,373,386
 *     the four 'camera and microphone' tests
 *
 * None carries a webkit exemption we inherit (unlike the ephemeral
 * page-cache-storage.spec.ts, which is `test.fail(browserName === 'webkit')`),
 * so PW's own glibc builds are expected to pass all of them: `isFrozenWebkit`
 * gates the camera set on debian11 / ubuntu20.04 / macOS<15 only, and PW's own
 * CI runs on ubuntu24.04. Running them against a published PW build says
 * whether an Alpine red belongs to our build or to the WebKit base PW pins —
 * the two moved together when PW rolled its base from 343e13bf (r2336, what
 * 1.62.1 ships) to 4d05d732 (r2339+, and the base we build), and a probe
 * against r2336 alone cannot separate them.
 *
 * The same file runs inside our Alpine conformance runner against our own
 * artifact, so the three arms differ only in the browser under test. Keep it
 * dependency-free and `require`-resolved from PW_MODULE for that reason.
 *
 * The assertions mirror the upstream specs exactly. Keep them that way: a
 * "simplified" control answers a different question than the failing test.
 *
 * Lives in scripts/ rather than conformance/debug/ on purpose: those probes are
 * mounted into OUR conformance runner image, while this one runs against a
 * stock ubuntu runner and a published PW install. Moving it under
 * playwright/alpine-browsers/** would also put it inside the producer
 * workflow's push path filter, so every edit would kick a multi-hour build.
 *
 * This is a probe, not a gate — a failing arm is the result, so the exit code
 * stays 0 and the verdict is on stdout as PROBE_RESULT lines.
 */
const http = require('node:http');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');

const { webkit } = require(process.env.PW_MODULE || 'playwright');

const results = [];
function record(name, verdict, detail) {
  results.push({ name, verdict, detail });
  console.log(`PROBE_RESULT ${name} ${verdict} ${detail}`);
}

async function probeContextmenuOrder(base) {
  const browser = await webkit.launch();
  try {
    const page = await browser.newPage();
    await page.goto(base);
    await page.evaluate(() => {
      const logEvent = e => console.log(e.type);
      document.addEventListener('mousedown', logEvent);
      document.addEventListener('mouseup', logEvent);
      document.addEventListener('contextmenu', logEvent);
    });
    const entries = [];
    page.on('console', message => entries.push(message.text()));
    await page.getByRole('button', { name: 'Click me' }).click({ button: 'right' });
    // The upstream spec polls; a fixed wait is enough here because a missing
    // event never arrives late — it is dropped by the browser, not delayed.
    await page.waitForTimeout(2000);
    const expected = ['mousedown', 'contextmenu', 'mouseup'];
    const got = JSON.stringify(entries);
    record('contextmenu-order',
      got === JSON.stringify(expected) ? 'PASS' : 'FAIL', got);

    // A left click on the same page, measured the same way. We drop mouseup
    // only on the right-click path, and the two candidates for that are a
    // mouseup that is never sent and one that is sent and swallowed while the
    // UI process still believes a context menu is up. If mouseup arrives here,
    // the dispatch side is fine and the swallow is in the context-menu path.
    entries.length = 0; // in place: the console listener captured this array
    await page.getByRole('button', { name: 'Click me' }).click();
    await page.waitForTimeout(1000);
    const afterLeftClick = JSON.stringify(entries);
    record('mouseup-on-left-click',
      afterLeftClick === JSON.stringify(['mousedown', 'mouseup']) ? 'PASS' : 'FAIL',
      afterLeftClick);

    // Drive the right button by hand, with the release a beat after the press.
    // click() sends both back to back, so a swallowed release and one the
    // browser simply never got around to look the same. Here the release is a
    // separate protocol call that has to be acknowledged, so if mouseup is
    // still missing the browser is dropping it rather than lagging.
    entries.length = 0;
    const box = await page.getByRole('button', { name: 'Click me' }).boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down({ button: 'right' });
    await page.waitForTimeout(500);
    await page.mouse.up({ button: 'right' });
    await page.waitForTimeout(1000);
    record('mouseup-on-explicit-right-release',
      entries.includes('mouseup') ? 'PASS' : 'FAIL', JSON.stringify(entries));
  } finally {
    await browser.close();
  }
}

async function probeCacheStoragePersistence(base) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'wk-persist-'));
  const context = await webkit.launchPersistentContext(profile);
  let after;
  try {
    const page = context.pages()[0] || await context.newPage();
    await page.goto(base);
    await page.evaluate// The mirror of the flag probe: turn the feature OFF. On an arm that shows mock
// devices by default, this settles whether --features reaches a PW-created page
// at all — if the devices vanish the settings object does reach them, and our
// own empty list under the same flag means the build cannot produce mock
// devices; if they survive, something other than the settings object enables
// the mock centre and that is what we still have to find.
async function probeCaptureDevicesWithMockDisabled(base) {
  const browser = await webkit.launch({ args: ['--features=!MockCaptureDevices'] });
  try {
    const context = await browser.newContext();
    await context.grantPermissions(['camera', 'microphone'], { origin: new URL(base).origin });
    const page = await context.newPage();
    await page.goto(base);
    const granted = await getUserMedia(page, { video: true, audio: true });
    record('capture-with-mock-disabled',
      granted.tracks ? 'INFO' : 'EMPTY', JSON.stringify(granted));
    await context.close();
  } finally {
    await browser.close();
  }
}

(async () => {
      const cache = await caches.open('repro-cache');
      await cache.put('/meta', new Response('payload'));
    });
    // Read it back in the same document first. The spec only checks after the
    // reload, so a failure there is ambiguous: it fits a write that never
    // landed just as well as one that landed and was lost. This separates them.
    const before = await page.evaluate(async () => {
      const cache = await caches.open('repro-cache');
      const resp = await cache.match('/meta');
      return resp ? await resp.text() : null;
    });
    record('cachestorage-before-reload',
      before === 'payload' ? 'PASS' : 'FAIL', JSON.stringify(before));
    // Same split as the ephemeral probe, against the store that actually
    // fails: a listed cache with no readable entry is a record write, an
    // empty list is the container itself.
    const persistentKeys = await page.evaluate(() => caches.keys());
    record('cachestorage-persistent-keys', persistentKeys.length ? 'INFO' : 'EMPTY',
      JSON.stringify(persistentKeys));
    await page.reload();
    after = await page.evaluate(async () => {
      const cache = await caches.open('repro-cache');
      const resp = await cache.match('/meta');
      return resp ? await resp.text() : null;
    });
  } finally {
    await context.close();
  }
  record('cachestorage-survives-reload',
    after === 'payload' ? 'PASS' : 'FAIL', JSON.stringify(after));
  // Read the profile only after the context is closed, so a write the network
  // process still holds has been flushed. Whether the entry reached disk at all
  // separates a data store that never persisted from one that persisted and
  // then failed to be read back.
  const onDisk = fs.readdirSync(profile, { recursive: true }).map(String).sort();
  record('cachestorage-on-disk-count', onDisk.length ? 'INFO' : 'EMPTY', String(onDisk.length));
  // The whole tree, not the paths matching /cache/. The record file is exactly
  // what neither listing showed, and nothing says its name carries the word —
  // so the earlier filter could not have found it either way. Diffing the full
  // trees names the file upstream writes and we do not.
  record('cachestorage-on-disk', 'INFO', JSON.stringify(onDisk));
  fs.rmSync(profile, { recursive: true, force: true });
}

// The persistent write does not land even in the same document, so the reload
// is not what loses it. This runs the identical put/match in an ordinary
// ephemeral context: a failure here too means CacheStorage writes are broken
// outright in our build, and the persistent profile is incidental.
async function probeCacheStorageEphemeral(base) {
  const browser = await webkit.launch();
  try {
    const page = await browser.newPage();
    await page.goto(base);
    const value = await page.evaluate(async () => {
      const cache = await caches.open('repro-cache');
      await cache.put('/meta', new Response('payload'));
      const resp = await cache.match('/meta');
      return resp ? await resp.text() : null;
    });
    record('cachestorage-ephemeral-same-document',
      value === 'payload' ? 'PASS' : 'FAIL', JSON.stringify(value));
    // caches.keys() answers a narrower question than match(): whether the
    // container registered the cache at all. A named cache with no readable
    // entry points at the record write; no cache at all points higher up.
    const keys = await page.evaluate(() => caches.keys());
    record('cachestorage-container-keys', keys.length ? 'INFO' : 'EMPTY',
      JSON.stringify(keys));
  } finally {
    await browser.close();
  }
}

// Mirrors the helper in permissions.spec.ts, sort included, so a verdict here
// means what the failing test means. `constraint` is carried too: it is the
// only field that distinguishes an OverconstrainedError raised over an empty
// device list from one raised over a device that exists but cannot comply.
async function getUserMedia(page, constraints) {
  return await page.evaluate(async constraints => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia(constraints);
      const tracks = stream.getTracks().map(track => ({ kind: track.kind, live: track.readyState === 'live' }));
      stream.getTracks().forEach(track => track.stop());
      tracks.sort((a, b) => a.kind.localeCompare(b.kind));
      return { tracks };
    } catch (error) {
      return { error: error.name, constraint: error.constraint };
    }
  }, constraints);
}

async function probeCaptureDevices(base) {
  const origin = new URL(base).origin;
  const browser = await webkit.launch();
  try {
    // The device list is what the four upstream specs cannot show. On Alpine
    // both the granted and the ungranted case return OverconstrainedError —
    // the same error on both sides of the permission gate, which means
    // getUserMedia never reaches that gate. An empty list explains that; a
    // populated one would move the search to the permission plumbing.
    const ungrantedContext = await browser.newContext();
    const ungrantedPage = await ungrantedContext.newPage();
    await ungrantedPage.goto(base);
    const devices = await ungrantedPage.evaluate(async () => {
      const list = await navigator.mediaDevices.enumerateDevices();
      return list.map(device => ({ kind: device.kind, label: device.label }));
    });
    record('capture-device-list', devices.length ? 'INFO' : 'EMPTY', JSON.stringify(devices));
    const ungranted = await getUserMedia(ungrantedPage, { video: true, audio: true });
    record('capture-ungranted-rejects',
      ungranted.error === 'NotAllowedError' ? 'PASS' : 'FAIL', JSON.stringify(ungranted));
    await ungrantedContext.close();

    const context = await browser.newContext();
    await context.grantPermissions(['camera', 'microphone'], { origin });
    const page = await context.newPage();
    await page.goto(base);
    const granted = await getUserMedia(page, { video: true, audio: true });
    const expected = JSON.stringify({
      tracks: [{ kind: 'audio', live: true }, { kind: 'video', live: true }],
    });
    record('capture-granted-captures',
      JSON.stringify(granted) === expected ? 'PASS' : 'FAIL', JSON.stringify(granted));
    // Labels are withheld until a capture permission is granted, so this second
    // enumeration is the first one that can name the devices. 'Mock audio
    // device 1' means WebKit's mock center is live; a '/dev/video0' or a
    // 'Monitor of ...' means the host simply has real GStreamer sources that
    // Alpine does not, which is a different fix entirely.
    const labels = await page.evaluate(async () => {
      const list = await navigator.mediaDevices.enumerateDevices();
      return list.map(device => `${device.kind}:${device.label}`);
    });
    record('capture-device-labels', labels.length ? 'INFO' : 'EMPTY', JSON.stringify(labels));
    await context.close();
  } finally {
    await browser.close();
  }
}

// Upstream enumerates 'Mock audio device 1' and friends, so its mock centre is
// live — and the only switch for that is the MockCaptureDevicesEnabled
// developer-preference override, which playwright-core never sends (its shipped
// bundle issues exactly seven Page.overrideSetting calls, none of them this
// one). MiniBrowser exposes the same settings through --features, so this asks
// the question directly: if the flag alone populates our device list, the fix
// is a launch flag rather than a rebuild.
//
// The identifier is `MockCaptureDevices`, which is what MiniBrowser's own
// --features=help prints; the preference key `MockCaptureDevicesEnabled` is
// NOT accepted, and an unknown name is answered with a stderr line and
// otherwise ignored, which reads exactly like a flag that did nothing.
//
// MEASURED: this changes nothing for us, and the reason is in PW's own
// MiniBrowser patch. Pages PW creates come from createWebViewImpl, which
// constructs the view with "web-context" and "is-controlled-by-automation"
// and drops the "settings" property upstream's code passed — so --features
// configures a settings object that PW-driven pages never see. Kept as a
// standing control: if a future build makes it bite, the assumption changed.
async function probeCaptureDevicesWithMockFeature(base) {
  const browser = await webkit.launch({ args: ['--features=MockCaptureDevices'] });
  try {
    const context = await browser.newContext();
    await context.grantPermissions(['camera', 'microphone'], { origin: new URL(base).origin });
    const page = await context.newPage();
    await page.goto(base);
    const granted = await getUserMedia(page, { video: true, audio: true });
    record('capture-granted-with-flag',
      granted.tracks ? 'PASS' : 'FAIL', JSON.stringify(granted));
    const labels = await page.evaluate(async () => {
      const list = await navigator.mediaDevices.enumerateDevices();
      return list.map(device => `${device.kind}:${device.label}`);
    });
    record('capture-with-mock-feature-flag', labels.length ? 'INFO' : 'EMPTY',
      JSON.stringify(labels));
    await context.close();
  } finally {
    await browser.close();
  }
}

(async () => {
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end('<html><body><button id="target">Click me</button></body></html>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}/`;

  console.log('EXECUTABLE=' + webkit.executablePath());
  try {
    await probeContextmenuOrder(base);
  } catch (e) {
    record('contextmenu-order', 'ERROR', String(e && e.message || e).split('\n')[0]);
  }
  try {
    await probeCacheStoragePersistence(base);
  } catch (e) {
    record('cachestorage-survives-reload', 'ERROR', String(e && e.message || e).split('\n')[0]);
  }
  try {
    await probeCacheStorageEphemeral(base);
  } catch (e) {
    record('cachestorage-ephemeral-same-document', 'ERROR', String(e && e.message || e).split('\n')[0]);
  }
  try {
    await probeCaptureDevices(base);
  } catch (e) {
    record('capture-devices', 'ERROR', String(e && e.message || e).split('\n')[0]);
  }
  try {
    await probeCaptureDevicesWithMockFeature(base);
  } catch (e) {
    record('capture-with-mock-feature-flag', 'ERROR', String(e && e.message || e).split('\n')[0]);
  }
  try {
    await probeCaptureDevicesWithMockDisabled(base);
  } catch (e) {
    record('capture-with-mock-disabled', 'ERROR', String(e && e.message || e).split('\n')[0]);
  }
  server.close();

  const summary = process.env.GITHUB_STEP_SUMMARY;
  if (summary) {
    const rows = results
      .map(r => `| ${process.env.ARM_LABEL || 'probe'} | ${r.name} | ${r.verdict} | \`${r.detail}\` |`)
      .join('\n');
    fs.appendFileSync(summary, rows + '\n');
  }
})();
