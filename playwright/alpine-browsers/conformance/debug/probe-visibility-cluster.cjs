// Minimal repro for the chromium-headless-shell visibility cluster
// (~150 page-suite fails on Alpine reporting `element is not visible`
// AFTER the locator resolves). One file, no upstream PW config — drives
// the PW SDK directly so we can probe launch-arg overrides without
// patching tests/library/playwright.config.ts.
//
// Usage:
//   IGNORE_DEFAULT_ARGS="--no-startup-window" EXTRA_ARGS="" node probe.cjs
//
// Env knobs:
//   IGNORE_DEFAULT_ARGS — comma- OR space-separated flags to omit from
//                         PW SDK's default chromium argv. Default
//                         `--no-startup-window` (first hypothesis).
//   EXTRA_ARGS          — space-separated flags to ADD. Defaults empty.
//   PW_DEBUG_API        — set to 1 by caller to dump every CDP call.
//
// Each probe prints one PASS/FAIL line per scenario so the CI runner
// can grep results.

const { chromium } = require('playwright');

const ok  = (cond, msg) => console.log(`${cond ? 'PASS' : 'FAIL'}: ${msg}`);
const log = (msg) => console.log(`INFO: ${msg}`);

const ignoreDefault = (process.env.IGNORE_DEFAULT_ARGS || '--no-startup-window')
  .split(/[\s,]+/)
  .filter(Boolean);
const extraArgs = (process.env.EXTRA_ARGS || '')
  .split(/\s+/)
  .filter(Boolean);

(async () => {
  log(`ignoreDefaultArgs=${JSON.stringify(ignoreDefault)} args=${JSON.stringify(extraArgs)}`);

  const browser = await chromium.launch({
    ignoreDefaultArgs: ignoreDefault,
    args: extraArgs,
  });
  log(`browser launched (version=${browser.version()})`);

  const context = await browser.newContext();
  const page = await context.newPage();

  // Probe 1 — viewport at newPage. The cluster hypothesis: layout never
  // initializes because viewport is 0×0 at newPage time.
  const viewport = await page.evaluate(() => ({
    w: window.innerWidth,
    h: window.innerHeight,
    dpr: window.devicePixelRatio,
  }));
  log(`viewport innerWidth=${viewport.w} innerHeight=${viewport.h} dpr=${viewport.dpr}`);
  ok(viewport.w > 0 && viewport.h > 0, `viewport non-zero`);

  // Probe 2 — page-check.spec.ts:20 minimal repro.
  await page.setContent(`<input id='checkbox' type='checkbox'>`);
  const cb = page.locator('input');
  const box = await cb.boundingBox();
  log(`checkbox boundingBox = ${JSON.stringify(box)}`);
  ok(box && box.width > 0 && box.height > 0, `checkbox has bounding box`);

  // Probe 3 — visibility check that PW's auto-wait uses internally.
  const visible = await cb.isVisible();
  ok(visible, `checkbox.isVisible() returns true`);

  // Probe 4 — actually try to check it. If this hangs, the cluster cause
  // is upstream of click dispatch (e.g., visibility check itself).
  try {
    await page.check('input', { timeout: 5000 });
    const checked = await page.evaluate(() => document.querySelector('#checkbox').checked);
    ok(checked === true, `page.check('input') flipped checkbox to checked`);
  } catch (e) {
    ok(false, `page.check('input') threw: ${e.message.split('\n')[0]}`);
  }

  // Probe 5 — basic mouse click to confirm event dispatch works once
  // visibility passes.
  await page.setContent(`<div id='target' style='width:100px;height:100px;background:red' onclick='this.dataset.clicked=1'>x</div>`);
  await page.click('#target', { timeout: 5000 }).catch(e => log(`click err: ${e.message.split('\n')[0]}`));
  const clicked = await page.evaluate(() => document.querySelector('#target').dataset.clicked);
  ok(clicked === '1', `div click dispatched click event`);

  await browser.close();
  log(`done`);
})().catch(e => { console.error('UNCAUGHT:', e); process.exit(2); });
