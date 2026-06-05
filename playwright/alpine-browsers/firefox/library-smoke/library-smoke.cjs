// Tier-2.5 — Playwright library-surface smoke for the PW-patched musl Firefox.
//
// Goes beyond smoke/launch.cjs (browser.launch + newContext + goto + screenshot
// + a single route call) to exercise the Juggler RPCs that surface PW library
// features. If Juggler returns wrong data or hangs on a given protocol call,
// the corresponding section catches it before consumers see it.
//
// Sections (one fresh BrowserContext each, hermetic but sharing one Browser
// to keep total wall-clock under a minute):
//
//   1. browser.version() — Browser.getInfo RPC
//   2. context isolation — Browser.createBrowserContext × 2, Network.setCookies
//   3. multi-page in one context — Target.* RPCs, Page.navigate twice
//   4. frames — Page.frameAttached / Runtime.evaluate in subframe
//   5. evaluate boundary — Runtime.evaluate with scalar / object / Promise return
//   6. dialogs — Dialog.opened + Dialog.dismiss/accept
//   7. screenshot — Page.screenshot returns valid PNG bytes
//   8. response observation — Network.requestWillBeSent / responseReceived
//
// CommonJS so NODE_PATH=/usr/local/lib/node_modules works (ESM ignores it).

const { firefox } = require('playwright');
const http = require('node:http');

const results = [];
const ok = (section, cond, msg) => {
  const status = cond ? 'OK  ' : 'FAIL';
  console.log(`${status} [${section}] ${msg}`);
  if (!cond) results.push({ section, msg });
};
const section = async (name, fn) => {
  try {
    await fn();
  } catch (err) {
    ok(name, false, `threw: ${err && err.stack ? err.stack.split('\n')[0] : err}`);
  }
};

(async () => {
  const executablePath = process.env.PLAYWRIGHT_FIREFOX_EXECUTABLE_PATH || undefined;
  const browser = await firefox.launch({
    executablePath,
    args: ['--remote-debugging-port=0'],
  });

  // Tiny in-process HTTP server for sections that need real responses
  // (response observation needs a status code; can't observe data: URLs).
  const server = http.createServer((req, res) => {
    if (req.url === '/iframe') {
      res.setHeader('content-type', 'text/html');
      res.end('<div id=inner>inside</div>');
      return;
    }
    if (req.url === '/dialog') {
      res.setHeader('content-type', 'text/html');
      res.end('<script>window.lastDialog = prompt("name?", "default")</script>');
      return;
    }
    res.setHeader('content-type', 'text/html');
    res.end(`<h1 id=h>${req.url}</h1>`);
  });
  // listen() is async — server.address() returns null until the 'listening'
  // event fires. Wrap in a promise so the port is bound before we read it.
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  const base = `http://127.0.0.1:${port}`;

  await section('1.version', async () => {
    const v = browser.version();
    ok('1.version', typeof v === 'string' && v.length > 0, `got ${JSON.stringify(v)}`);
  });

  await section('2.context-isolation', async () => {
    const a = await browser.newContext();
    const b = await browser.newContext();
    await a.addCookies([{ name: 'k', value: 'A', url: base }]);
    await b.addCookies([{ name: 'k', value: 'B', url: base }]);
    const cookA = await a.cookies(base);
    const cookB = await b.cookies(base);
    ok('2.context-isolation', cookA.find(c => c.name === 'k')?.value === 'A', 'ctx-a sees A');
    ok('2.context-isolation', cookB.find(c => c.name === 'k')?.value === 'B', 'ctx-b sees B');
    await a.close(); await b.close();
  });

  await section('3.multi-page', async () => {
    const ctx = await browser.newContext();
    const p1 = await ctx.newPage();
    const p2 = await ctx.newPage();
    await Promise.all([p1.goto(base + '/one'), p2.goto(base + '/two')]);
    const t1 = await p1.locator('#h').textContent();
    const t2 = await p2.locator('#h').textContent();
    ok('3.multi-page', t1 === '/one' && t2 === '/two', `p1=${t1} p2=${t2}`);
    ok('3.multi-page', ctx.pages().length === 2, `context.pages.length=${ctx.pages().length}`);
    await ctx.close();
  });

  await section('4.frames', async () => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.setContent(`<iframe src="${base}/iframe"></iframe>`);
    await page.waitForLoadState('networkidle');
    const frames = page.frames();
    ok('4.frames', frames.length === 2, `frames.length=${frames.length}`);
    const inner = await frames[1].locator('#inner').textContent();
    ok('4.frames', inner === 'inside', `subframe text=${inner}`);
    await ctx.close();
  });

  await section('5.evaluate', async () => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    const n = await page.evaluate(() => 6 * 7);
    const o = await page.evaluate(() => ({ a: 1, b: [2, 3] }));
    const p = await page.evaluate(() => Promise.resolve('async'));
    ok('5.evaluate', n === 42, `scalar=${n}`);
    ok('5.evaluate', o.a === 1 && o.b[1] === 3, `object=${JSON.stringify(o)}`);
    ok('5.evaluate', p === 'async', `promise=${p}`);
    await ctx.close();
  });

  await section('6.dialogs', async () => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    page.on('dialog', d => d.accept('answer'));
    await page.goto(base + '/dialog');
    const last = await page.evaluate(() => window.lastDialog);
    ok('6.dialogs', last === 'answer', `prompt result=${last}`);
    await ctx.close();
  });

  await section('7.screenshot', async () => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.setContent('<h1>hello</h1>');
    const buf = await page.screenshot();
    const isPng = buf.length > 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47;
    ok('7.screenshot', isPng, `${buf.length} bytes, PNG magic=${isPng}`);
    await ctx.close();
  });

  await section('8.response', async () => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    const responses = [];
    page.on('response', r => responses.push({ url: r.url(), status: r.status() }));
    await page.goto(base + '/probe');
    const navResp = responses.find(r => r.url.endsWith('/probe'));
    ok('8.response', !!navResp, `navigation response observed: ${!!navResp}`);
    ok('8.response', navResp && navResp.status === 200, `status=${navResp && navResp.status}`);
    await ctx.close();
  });

  await browser.close();
  server.close();

  if (results.length) {
    console.error(`\n${results.length} FAIL(s):`);
    for (const r of results) console.error(`  [${r.section}] ${r.msg}`);
    process.exit(1);
  }
  console.log('\nAll sections passed.');
})().catch(err => {
  console.error('fatal:', err);
  process.exit(2);
});
