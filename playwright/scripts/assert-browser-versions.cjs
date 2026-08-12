#!/usr/bin/env node
/*
 * Asserts that the browsers staged in THIS image are the ones the image's own
 * Playwright expects.
 *
 * The producer's Tier-1 smokes check each artifact against Playwright's pin at
 * build time, but the consumer image re-states that pin independently: the
 * `CHS_REV` / `FF_REV` / `WK_REV` build-args in playwright/Dockerfile.alpine are
 * maintained by hand, and Playwright locates a browser by DIRECTORY NAME
 * (`firefox-<rev>/`). So a stale or mistyped rev resolves happily and the SDK
 * drives an older browser than it believes it has, with nothing failing.
 *
 * That is not hypothetical: the alpine image shipped Firefox 147.0.1 in a
 * `firefox-1522/` directory while its Playwright 1.60 pinned 150.0.2, and the
 * only reason anyone noticed was the runtime perf probe printing
 * browser.version() next to the official image's.
 *
 * CommonJS so NODE_PATH resolution reaches the global install — ESM ignores it.
 */

const path = require('node:path');
const { createRequire } = require('node:module');

const BROWSERS = ['chromium', 'firefox', 'webkit'];

/*
 * `playwright-core` is not resolvable from here directly: pnpm's global install
 * exposes only `playwright` at the top level and keeps its dependencies inside
 * the .pnpm store, so NODE_PATH never reaches the core package. Resolving from
 * playwright's own location follows the link the way playwright itself does.
 */
const requireFromPlaywright = createRequire(require.resolve('playwright'));
const CORE_ROOT = path.dirname(requireFromPlaywright.resolve('playwright-core'));

/*
 * Chromium is published twice — the full browser and the headless shell — and
 * our alpine image stages the shell. Both are acceptable answers for the
 * `chromium` browser type; anything else is drift.
 */
function expectedVersions(browsersJson, name) {
  const names = name === 'chromium' ? ['chromium', 'chromium-headless-shell'] : [name];
  return browsersJson.browsers
    .filter((b) => names.includes(b.name))
    .map((b) => b.browserVersion)
    .filter(Boolean);
}

async function main() {
  const playwright = require('playwright');
  // browsers.json is not in playwright-core's `exports` map — read it by path.
  const browsersJson = require(path.join(CORE_ROOT, 'browsers.json'));
  const playwrightVersion = require(path.join(CORE_ROOT, 'package.json')).version;
  console.log(`playwright-core ${playwrightVersion}`);

  const mismatches = [];
  for (const name of BROWSERS) {
    const expected = expectedVersions(browsersJson, name);
    if (!expected.length) {
      mismatches.push(`${name}: no entry in browsers.json`);
      continue;
    }

    let actual;
    try {
      const browser = await playwright[name].launch();
      actual = browser.version();
      await browser.close();
    } catch (err) {
      mismatches.push(`${name}: launch failed — ${err.message}`);
      continue;
    }

    if (expected.includes(actual)) {
      console.log(`OK  : ${name} ${actual}`);
    } else {
      console.log(`FAIL: ${name} ${actual}, expected ${expected.join(' or ')}`);
      mismatches.push(`${name}: staged ${actual}, playwright ${playwrightVersion} expects ${expected.join(' or ')}`);
    }
  }

  if (mismatches.length) {
    console.error('\nStaged browsers do not match this image\'s Playwright:');
    for (const m of mismatches) {
      console.error(`  - ${m}`);
    }
    console.error(
      '\nEither a *_REV build-arg in the Dockerfile is stale, or the producer tag it '
        + 'points at holds an older binary than its name claims.',
    );
    process.exit(1);
  }
  console.log('\nall staged browsers match');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
