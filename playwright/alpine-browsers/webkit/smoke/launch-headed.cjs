// Tier-2 headed smoke: drive MiniBrowser-gtk via the Playwright SDK.
// pw_run.sh dispatches headed launches (headless: false) → MiniBrowser-gtk.
// Requires Xvfb (or any X11 display) — caller sets DISPLAY=:99 first.
//
// Mirrors smoke/launch.cjs shape but with headless: false. Same OK gates.
//
// Catches: GTK port linkage, display init, GdkX11/cairo/pango bring-up,
// libwpebackend-fdo NOT touched on this path (GTK uses native GTK4 widgets).
//
// If the WPE Tier-2 succeeded but this one hangs/crashes, the bug is
// GTK-port-specific (not in shared JSC/WTF/WebCore).

const { webkit } = require('playwright');

const ok = (cond, msg) => { if (!cond) { console.error('FAIL:', msg); process.exit(1); } else { console.log('OK  :', msg); } };

(async () => {
  const browser = await webkit.launch({ headless: false });
  ok(browser, 'webkit.launch({headless:false}) returned a browser');

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

  await browser.close();
  console.log('headed smoke OK');
})().catch(e => { console.error(e); process.exit(1); });
