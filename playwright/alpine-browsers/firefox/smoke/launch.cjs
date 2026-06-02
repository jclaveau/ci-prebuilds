// Tier-2 smoke: drive the patched Firefox via the Playwright SDK enough to
// exercise Juggler. If the patches are broken (binary built but Juggler
// internals misaligned), browser.newContext() or page.goto() will hang or
// throw — that's exactly what we want to catch before publishing.
//
// CommonJS so NODE_PATH=/usr/local/lib/node_modules works (ESM ignores it).

const { firefox } = require('playwright');

const ok = (cond, msg) => { if (!cond) { console.error('FAIL:', msg); process.exit(1); } else { console.log('OK  :', msg); } };

(async () => {
  // PLAYWRIGHT_FIREFOX_EXECUTABLE_PATH only affects `playwright install`, not
  // `firefox.launch()` runtime resolution — we must pass executablePath
  // explicitly here.
  const executablePath = process.env.PLAYWRIGHT_FIREFOX_EXECUTABLE_PATH || undefined;
  // musl-build Juggler-dormant workaround: Juggler's
  // command-line-handler:m-remote entry is shadowed by Mozilla's RemoteAgent
  // (both register under the same name). JugglerFactory only instantiates as
  // a side-effect of RemoteAgent activating. Passing --remote-debugging-port=0
  // wakes RemoteAgent, which in turn unblocks Juggler. Port 0 = ephemeral, the
  // BiDi server we don't use binds to a throwaway port.
  const browser = await firefox.launch({
    executablePath,
    args: ['--remote-debugging-port=0'],
  });
  ok(browser, 'firefox.launch() returned a browser');

  const ctx = await browser.newContext();
  ok(ctx, 'browser.newContext()');

  const page = await ctx.newPage();
  ok(page, 'context.newPage()');

  await page.goto('data:text/html,<h1 id=h>ok</h1>');
  const title = await page.locator('#h').textContent();
  ok(title === 'ok', `page.locator textContent (got: ${JSON.stringify(title)})`);

  let intercepted = 0;
  await page.route('**/*.png', route => { intercepted++; route.abort(); });
  await page.setContent('<img src="/x.png">').catch(() => {});
  ok(intercepted >= 1, `page.route fired (intercepted=${intercepted})`);

  const png = await page.screenshot();
  ok(png && png.length > 100, `page.screenshot returned ${png?.length} bytes`);

  await browser.close();
  console.log('smoke OK');
})().catch(e => { console.error(e); process.exit(1); });
