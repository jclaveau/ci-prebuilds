// Does a CacheStorage entry survive page.reload()? Mirrors
// tests/library/defaultbrowsercontext-2.spec.ts:285, which is red on our
// WebKit and green on the official image.
//
// Reads the entry BEFORE the reload as well as after. That control is the whole
// point: "null after reload" and "null always" are different bugs — one is
// persistence, the other is the Cache API not storing at all — and the test
// only asserts the second read, so it cannot tell them apart.
//
// Runs both a persistent and a non-persistent context because the failing test
// uses launchPersistent. If only the persistent arm is null the fault is in the
// on-disk store; if both are, it is the Cache API itself.

const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { webkit } = require('playwright-core');

async function writeEntry(page) {
  return await page.evaluate(async () => {
    try {
      const cache = await caches.open('repro-cache');
      await cache.put('/meta', new Response('payload'));
      return 'ok';
    } catch (error) {
      return 'ERR ' + error.name + ': ' + error.message;
    }
  });
}

async function inspectCache(page) {
  return await page.evaluate(async () => {
    try {
      const names = await caches.keys();
      const cache = await caches.open('repro-cache');
      const reqs = await cache.keys();
      return 'caches.keys=[' + names.join(',') + '] cache.keys=['
        + reqs.map(r => r.url).join(',') + ']';
    } catch (error) {
      return 'ERR ' + error.name + ': ' + error.message;
    }
  });
}

async function readEntry(page) {
  return await page.evaluate(async () => {
    try {
      const cache = await caches.open('repro-cache');
      const resp = await cache.match('/meta');
      return resp ? await resp.text() : null;
    } catch (error) {
      return 'ERR ' + error.name + ': ' + error.message;
    }
  });
}

function describeTree(root, limit = 12) {
  const found = [];
  const walk = dir => {
    let entries = [];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (found.length < limit) {
        found.push(path.relative(root, full) + ' (' + fs.statSync(full).size + 'B)');
      }
    }
  };
  walk(root);
  return found;
}

(async () => {
  const server = http.createServer((_, response) => {
    response.setHeader('content-type', 'text/html');
    response.end('<h1>cachestorage probe</h1>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = 'http://localhost:' + server.address().port;
  console.log('origin   ' + origin);

  // ── persistent, the mode the failing test uses ──
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wk-cache-'));
  const context = await webkit.launchPersistentContext(userDataDir);
  const page = await context.newPage();
  await page.goto(origin + '/');
  const put = await writeEntry(page);
  // Poll rather than read once: "null immediately" and "null forever" are
  // different bugs, and the upstream test only ever reads once so it cannot
  // separate a flush race from a broken read path.
  const before = await readEntry(page);
  const delayed = [];
  for (const ms of [250, 1000, 3000]) {
    await page.waitForTimeout(ms);
    delayed.push(ms + 'ms:' + String(await readEntry(page)));
  }
  const inspection = await inspectCache(page);
  await page.reload();
  const after = await readEntry(page);
  await context.close();

  // ── non-persistent, for contrast ──
  const browser = await webkit.launch();
  console.log('browser  ' + browser.version());
  const ephemeralContext = await browser.newContext();
  const ephemeralPage = await ephemeralContext.newPage();
  await ephemeralPage.goto(origin + '/');
  await writeEntry(ephemeralPage);
  const ephemeralBefore = await readEntry(ephemeralPage);
  await ephemeralPage.reload();
  const ephemeralAfter = await readEntry(ephemeralPage);
  await ephemeralContext.close();
  await browser.close();

  console.log('');
  console.log('mode            put     before reload   after reload');
  console.log('--------------  ------  --------------  --------------');
  console.log('persistent'.padEnd(16) + String(put).padEnd(8)
    + String(before).padEnd(16) + String(after));
  console.log('  persistent re-reads without reloading: ' + delayed.join('  '));
  console.log('  persistent cache contents: ' + inspection);
  console.log('non-persistent'.padEnd(16) + 'ok'.padEnd(8)
    + String(ephemeralBefore).padEnd(16) + String(ephemeralAfter));

  console.log('');
  console.log('files under the persistent user-data-dir:');
  const tree = describeTree(userDataDir);
  if (!tree.length) {
    console.log('  (none — nothing was written to disk at all)');
  }
  for (const entry of tree) {
    console.log('  ' + entry);
  }

  server.close();
})().catch(error => {
  console.error('probe failed:', error);
  process.exit(1);
});
