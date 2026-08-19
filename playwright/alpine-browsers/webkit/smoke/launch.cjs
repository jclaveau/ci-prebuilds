// Tier-2 smoke: drive the WPE+GTK MiniBrowser dist via the Playwright SDK.
// Mirrors firefox/smoke/launch.cjs shape — launch the headless port, exercise
// page.goto/locator/route/screenshot, close. If the build is broken (binaries
// staged but RemoteInspector handshake misaligned on musl), launch() or
// newContext() hangs — that's the FF #60-style musl wall we want to catch
// before publishing.
//
// CommonJS so NODE_PATH=/usr/local/lib/node_modules works (ESM ignores it).

const fs = require('node:fs');
const path = require('node:path');

const { webkit } = require('playwright');

const ok = (cond, msg) => { if (!cond) { console.error('FAIL:', msg); process.exit(1); } else { console.log('OK  :', msg); } };

(async () => {
  // PW's webkit launcher resolves the binary via PLAYWRIGHT_BROWSERS_PATH +
  // browsers.json's webkit.revision (looks for `webkit-<rev>/`). pw_run.sh
  // dispatches headless → MiniBrowser-wpe. No executablePath override
  // needed when the path env is set correctly in the Dockerfile.
  const browser = await webkit.launch();
  ok(browser, 'webkit.launch() returned a browser');

  // browser.version() does NOT read the browser. playwright-core carries
  // `const BROWSER_VERSION = '26.5'` in webkit/wkBrowser.ts and returns it
  // verbatim, and EXPECTED_WEBKIT_VERSION comes from the same package's
  // browsers.json — so this compares PW against itself and passes whatever
  // WebKit we built. Kept because a mismatch still means the installed client
  // disagrees with its own pin, but it can NOT catch a mislabelled artifact.
  const expected = process.env.EXPECTED_WEBKIT_VERSION;
  ok(expected, 'EXPECTED_WEBKIT_VERSION is set');
  const actual = browser.version();
  ok(actual === expected, `browser.version() = ${actual} (playwright-core constant), expected ${expected}`);

  // The real check: read the engine version off the shipped library. WebKit's
  // libtool triple in Source/cmake/OptionsWPE.cmake produces
  // libWPEWebKit-<api>.so.<current-age>.<age>.<revision>, and it moves with the
  // base — (11 0 10) → 1.10.0 at WebKit 343e13bf, (11 2 10) → 1.10.2 at
  // 4d05d732. So this is a value only the built binary can supply, checked
  // against a checked-in expectation.
  const expectedSo = process.env.EXPECTED_WPE_SOVERSION;
  ok(expectedSo, 'EXPECTED_WPE_SOVERSION is set');
  const distDir = path.dirname(webkit.executablePath());
  const soRe = /^libWPEWebKit-[\d.]+\.so\.(\d+\.\d+\.\d+)$/;
  const found = fs.readdirSync(distDir).map(n => n.match(soRe)).filter(Boolean);
  ok(found.length > 0,
    `found a versioned libWPEWebKit in ${distDir} (saw: ${fs.readdirSync(distDir).filter(n => n.startsWith('libWPEWebKit')).join(', ') || 'none'})`);
  const soVersion = found[0][1];
  ok(soVersion === expectedSo,
    `libWPEWebKit so-version = ${soVersion}, expected ${expectedSo}`);

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
  console.log('smoke OK');
})().catch(e => { console.error(e); process.exit(1); });
