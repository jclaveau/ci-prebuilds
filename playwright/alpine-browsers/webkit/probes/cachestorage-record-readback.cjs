// Can a CacheStorage record this build WROTE be read back — by itself or by
// anyone else?
//
// Run it twice against one profile, once per build, so both records live in the
// same directory under the same salt, uuid and origin:
//
//   FRESH=1 PUT_KEY=/meta  ./run-probe.sh official   cachestorage-record-readback.cjs
//            PUT_KEY=/meta2 ./run-probe.sh <wk-tag>  cachestorage-record-readback.cjs
//                           ./run-probe.sh <wk-tag>  cachestorage-record-readback.cjs
//                           ./run-probe.sh official  cachestorage-record-readback.cjs
//
// Sharing the profile is what makes it a clean experiment: the read path, the
// directory names, the salts, cacheslist and origin are all held constant, so a
// record that only ONE of the two builds produced going missing can only be the
// write path. That is how the missing encoder line was found — both builds read
// official's /meta and neither reads ours' /meta2.
//
// The port is pinned because the cache is keyed by origin: a random port makes
// every cell trivially empty.
const fs = require('fs');
const http = require('http');
const path = require('path');
const { webkit } = require('playwright-core');

const PORT = Number(process.env.PROBE_PORT || 34567);
const UDD = '/data/udd-shared';
const KEY = process.env.PUT_KEY;

(async () => {
  const server = http.createServer((_, response) => {
    response.setHeader('content-type', 'text/html');
    response.end('<h1>append</h1>');
  });
  await new Promise(resolve => server.listen(PORT, '127.0.0.1', resolve));
  const origin = 'http://localhost:' + PORT;

  if (process.env.FRESH === '1') {
    fs.rmSync(UDD, { recursive: true, force: true });
  }
  const context = await webkit.launchPersistentContext(UDD);
  const page = await context.newPage();
  await page.goto(origin + '/');
  if (KEY) {
    console.log('put ' + KEY + ': ' + await page.evaluate(async key => {
      const cache = await caches.open('repro-cache');
      await cache.put(key, new Response('payload-' + key));
      return 'ok';
    }, KEY));
    await page.waitForTimeout(1000);
  }
  console.log('read: ' + await page.evaluate(async () => {
    const cache = await caches.open('repro-cache');
    const keys = (await cache.keys()).map(r => new URL(r.url).pathname);
    return 'cache.keys=[' + keys.join(',') + ']';
  }));
  await context.close();

  const walk = dir => fs.readdirSync(dir, { withFileTypes: true })
    .flatMap(e => e.isDirectory() ? walk(path.join(dir, e.name))
      : [path.relative(UDD, path.join(dir, e.name))
         + ' (' + fs.statSync(path.join(dir, e.name)).size + 'B)']);
  for (const line of walk(path.join(UDD, 'CacheStorage'))) {
    console.log('  ' + line);
  }
  server.close();
})().catch(error => {
  console.error('probe failed:', error);
  process.exit(1);
});
