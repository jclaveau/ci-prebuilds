// Tier-2 smoke for musl chrome-headless-shell. The Firefox launch.cjs passes
// executablePath explicitly because PW's PLAYWRIGHT_FIREFOX_EXECUTABLE_PATH
// only governs install-time, not runtime resolution. For chromium the
// invariant is different: we stage the artifact at PW SDK's auto-discovery
// cache path, so we do NOT pass executablePath — if discovery is wired
// correctly, launch() finds the binary on its own.
//
// This is also the assertion that `playwright.config.ts` doesn't need to
// change: PW SDK at version ${PW_VERSION} reads ITS OWN browsers.json,
// derives the revision, looks at ${PLAYWRIGHT_BROWSERS_PATH}/chromium_headless_shell-<rev>/,
// and launches what it finds — no env-var override needed.

const { chromium } = require('playwright');

const ok = (cond, msg) => { if (!cond) { console.error('FAIL:', msg); process.exit(1); } else { console.log('OK  :', msg); } };

(async () => {
  // NO executablePath. PW SDK auto-discovery is the contract.
  const browser = await chromium.launch();
  ok(browser, 'chromium.launch() returned a browser (auto-discovered from cache path)');

  const ctx = await browser.newContext();
  ok(ctx, 'browser.newContext()');

  const page = await ctx.newPage();
  ok(page, 'context.newPage()');

  await page.goto('data:text/html,<h1 id=h>ok</h1>');
  const title = await page.locator('#h').textContent();
  ok(title === 'ok', `page.locator textContent (got: ${JSON.stringify(title)})`);

  let intercepted = 0;
  await page.route('**/*.png', route => { intercepted++; route.abort(); });
  // Absolute URL — relative URLs on data: pages don't resolve, so page.route
  // would have nothing to intercept. Same gotcha as Firefox smoke.
  await page.setContent('<img src="http://x.invalid/x.png">').catch(() => {});
  ok(intercepted >= 1, `page.route fired (intercepted=${intercepted})`);

  const png = await page.screenshot();
  ok(png && png.length > 100, `page.screenshot returned ${png?.length} bytes`);

  await browser.close();
  console.log('smoke OK');
})().catch(e => { console.error(e); process.exit(1); });
