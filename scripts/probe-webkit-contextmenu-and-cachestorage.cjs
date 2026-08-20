#!/usr/bin/env node
/*
 * Control leg for the two WebKit conformance reds that survive on Alpine:
 *
 *   tests/page/page-click.spec.ts:1203
 *     'should fire contextmenu event on right click in correct order'
 *   tests/library/defaultbrowsercontext-2.spec.ts:285
 *     'CacheStorage entry should survive page.reload()'
 *
 * Neither carries a webkit exemption upstream (unlike the ephemeral
 * page-cache-storage.spec.ts, which is `test.fail(browserName === 'webkit')`),
 * so PW's own glibc builds are expected to pass both. Running them against a
 * published PW build says whether an Alpine red belongs to our build or to the
 * WebKit base PW pins — the two moved together when PW rolled its base from
 * 343e13bf (r2336, what 1.62.1 ships) to 4d05d732 (r2339+), and a probe against
 * r2336 alone cannot separate them.
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
  } finally {
    await browser.close();
  }
}

async function probeCacheStoragePersistence(base) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'wk-persist-'));
  const context = await webkit.launchPersistentContext(profile);
  try {
    const page = context.pages()[0] || await context.newPage();
    await page.goto(base);
    await page.evaluate(async () => {
      const cache = await caches.open('repro-cache');
      await cache.put('/meta', new Response('payload'));
    });
    await page.reload();
    const after = await page.evaluate(async () => {
      const cache = await caches.open('repro-cache');
      const resp = await cache.match('/meta');
      return resp ? await resp.text() : null;
    });
    record('cachestorage-survives-reload',
      after === 'payload' ? 'PASS' : 'FAIL', JSON.stringify(after));
  } finally {
    await context.close();
    fs.rmSync(profile, { recursive: true, force: true });
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
  server.close();

  const summary = process.env.GITHUB_STEP_SUMMARY;
  if (summary) {
    const rows = results
      .map(r => `| ${process.env.ARM_LABEL || 'probe'} | ${r.name} | ${r.verdict} | \`${r.detail}\` |`)
      .join('\n');
    fs.appendFileSync(summary, rows + '\n');
  }
})();
