// Tier-2 smoke: drive the WPE+GTK MiniBrowser dist via the Playwright SDK.
// Mirrors firefox/smoke/launch.cjs shape — launch the headless port, exercise
// page.goto/locator/route/screenshot, close. If the build is broken (binaries
// staged but RemoteInspector handshake misaligned on musl), launch() or
// newContext() hangs — that's the FF #60-style musl wall we want to catch
// before publishing.
//
// CommonJS so NODE_PATH=/usr/local/lib/node_modules works (ESM ignores it).

const { webkit } = require('playwright');

const ok = (cond, msg) => { if (!cond) { console.error('FAIL:', msg); process.exit(1); } else { console.log('OK  :', msg); } };

(async () => {
  // PW's webkit launcher resolves the binary via PLAYWRIGHT_BROWSERS_PATH +
  // browsers.json's webkit.revision (looks for `webkit-<rev>/`). pw_run.sh
  // dispatches headless → MiniBrowser-wpe. No executablePath override
  // needed when the path env is set correctly in the Dockerfile.
  const browser = await webkit.launch();
  ok(browser, 'webkit.launch() returned a browser');

  // WebKit has no Tier-1 `--version` leg — MiniBrowser-wpe reports none — so
  // this is the only place the artifact's version gets checked at all, and
  // promote-webkit needs this job, so it gates the `wk-<version>` tag. Without
  // it that tag is derived purely from PW's pin and will happily label a stale
  // binary, which is precisely how `ff-150.0.2` ended up on a Firefox 147.0.1.
  // Required rather than skip-if-unset: an unset env would make the assertion
  // vacuous and nothing would say so.
  const expected = process.env.EXPECTED_WEBKIT_VERSION;
  ok(expected, 'EXPECTED_WEBKIT_VERSION is set');
  const actual = browser.version();
  ok(actual === expected, `browser.version() = ${actual}, expected ${expected}`);

  const ctx = await browser.newContext();
  ok(ctx, 'browser.newContext()');

  const page = await ctx.newPage();
  ok(page, 'context.newPage()');

  await page.goto('data:text/html,<h1 id=h>ok</h1>');
  const title = await page.locator('#h').textContent();
  ok(title === 'ok', `page.locator textContent (got: ${JSON.stringify(title)})`);

  let intercepted = 0;
  await page.route('**/*.png', route => { intercepted++; route.abort(); });
  await page.setContent('<img src="http://x.invalid/x.png">').catch(() => {});
  ok(intercepted >= 1, `page.route fired (intercepted=${intercepted})`);

  const png = await page.screenshot();
  ok(png && png.length > 100, `page.screenshot returned ${png?.length} bytes`);

  // Regression: the right-click release must reach the page.
  //
  // Mirrors tests/page/page-click.spec.ts:1203 'should fire contextmenu event
  // on right click in correct order' (microsoft/playwright#26515), which every
  // non-Windows-chromium browser is expected to pass:
  //
  //     await expect.poll(() => entries).toEqual(['mousedown', 'contextmenu', 'mouseup'])
  //
  // We emitted only ['mousedown', 'contextmenu']. WebPageProxy::showContextMenu
  // calls discardQueuedMouseEvents(), whose own comment says it drops events
  // "if we take too long to enter the nested runloop" — and locator.click()
  // PIPELINES move/down/up, so our release is already queued when
  // ShowContextMenu arrives and gets discarded. Sending the same three events
  // awaited one at a time passes, which is why this uses click(): only the
  // pipelined shape reproduces it.
  await page.setContent('<button id="target">Click me</button>');
  await page.evaluate(() => {
    const logEvent = e => console.log(e.type);
    document.addEventListener('mousedown', logEvent);
    document.addEventListener('mouseup', logEvent);
    document.addEventListener('contextmenu', logEvent);
  });
  const mouseEvents = [];
  page.on('console', message => mouseEvents.push(message.text()));
  await page.getByRole('button', { name: 'Click me' }).click({ button: 'right' });
  // A dropped event never arrives late, but poll anyway so a slow runner
  // reports the real order rather than a truncated one.
  for (let attempt = 0; attempt < 30 && mouseEvents.length < 3; attempt++) {
    await page.waitForTimeout(100);
  }
  ok(JSON.stringify(mouseEvents) === JSON.stringify(['mousedown', 'contextmenu', 'mouseup']),
    `right click event order (got: ${JSON.stringify(mouseEvents)})`);

  await browser.close();
  console.log('smoke OK');
})().catch(e => { console.error(e); process.exit(1); });
