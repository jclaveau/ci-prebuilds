#!/usr/bin/env node
/*
 * Why does launchPersistentContext hang on the musl WebKit 26.5 build?
 *
 * 64 of the 155 conformance failures are one bug wearing three hats:
 * defaultbrowsercontext-1/-2 (36), page-close (18) and
 * browsercontext-storage-state (10) all go through launchPersistentContext, and
 * they fail as "Test timeout of 30000ms exceeded" on the FIRST line — before any
 * page exists, which is why their error-contexts carry no snapshot. Everything
 * downstream in the same worker then reports "Test ended" / "Target closed",
 * which is what made it look like 90 separate crashes.
 *
 * Ordinary browser.launch() + newContext() is fine: smoke passes, and the great
 * majority of non-persistent tests pass. The only difference is that a persistent
 * context asks WebKit for an ON-DISK WebsiteDataStore.
 *
 * So this bisects the disk-backed path rather than guessing at a fix and paying
 * ~10h per attempt. Each variant is independent and gets its own timeout, so one
 * hang does not hide the others.
 *
 * Usage: node probe-persistent-context.cjs [--timeout 25000]
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
const TIMEOUT = Number(arg('timeout', '25000'));

function tmpProfile(where) {
  const base = where === 'home' ? (process.env.HOME || os.tmpdir()) : os.tmpdir();
  return fs.mkdtempSync(path.join(base, 'pcprobe-'));
}

async function withTimeout(label, fn) {
  let timer;
  const t0 = Date.now();
  try {
    const res = await Promise.race([
      fn(),
      new Promise((_, rej) => { timer = setTimeout(() => rej(new Error(`TIMEOUT after ${TIMEOUT}ms`)), TIMEOUT); }),
    ]);
    console.log(`PASS  ${label}  (${Date.now() - t0}ms)`);
    return res;
  } catch (e) {
    console.log(`FAIL  ${label}  (${Date.now() - t0}ms)  ${String(e.message || e).split('\n')[0].slice(0, 160)}`);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

(async () => {
  const { webkit } = require('playwright');

  console.log('--- environment');
  for (const k of ['HOME', 'XDG_RUNTIME_DIR', 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'TMPDIR',
                   'WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS', 'WEBKIT_FORCE_SANDBOX',
                   'PLAYWRIGHT_BROWSERS_PATH'])
    console.log(`  ${k}=${process.env[k] ?? '<unset>'}`);
  const home = process.env.HOME || '';
  console.log(`  HOME writable: ${(() => { try { fs.accessSync(home, fs.constants.W_OK); return true; } catch { return false; } })()}`);
  console.log(`  /tmp writable: ${(() => { try { fs.accessSync('/tmp', fs.constants.W_OK); return true; } catch { return false; } })()}`);

  console.log('--- control: NON-persistent (this is known to work)');
  await withTimeout('launch + newContext + newPage', async () => {
    const b = await webkit.launch();
    const c = await b.newContext();
    await c.newPage();
    await b.close();
    return true;
  });

  console.log('--- persistent variants');

  // 1. The plain case the tests use.
  await withTimeout('launchPersistentContext(/tmp profile)', async () => {
    const dir = tmpProfile('tmp');
    const c = await webkit.launchPersistentContext(dir, {});
    await c.close();
    return true;
  });

  // 2. Profile under $HOME — if only this one works, the data store is resolving
  //    something relative to HOME rather than to the profile we passed.
  await withTimeout('launchPersistentContext($HOME profile)', async () => {
    const dir = tmpProfile('home');
    const c = await webkit.launchPersistentContext(dir, {});
    await c.close();
    return true;
  });

  // 3. Sandbox explicitly disabled for the browser process itself. The runner sets
  //    these for the shell, but a hang here vs a pass in (1) localises it to bwrap.
  await withTimeout('launchPersistentContext(sandbox env forced off)', async () => {
    const dir = tmpProfile('tmp');
    const c = await webkit.launchPersistentContext(dir, {
      env: {
        ...process.env,
        WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS: '1',
        WEBKIT_FORCE_SANDBOX: '0',
      },
    });
    await c.close();
    return true;
  });

  // 4. Same, plus WebKit's own logging. If it hangs, the tail of stderr says which
  //    subsystem it is sitting in — that is the whole point of this probe.
  await withTimeout('launchPersistentContext(WEBKIT_DEBUG=all, stderr captured)', async () => {
    const dir = tmpProfile('tmp');
    const c = await webkit.launchPersistentContext(dir, {
      env: { ...process.env, WEBKIT_DEBUG: 'all' },
    });
    await c.close();
    return true;
  });

  // 5. Does it hang on CREATE, or only once something touches storage?
  await withTimeout('launchPersistentContext + goto about:blank', async () => {
    const dir = tmpProfile('tmp');
    const c = await webkit.launchPersistentContext(dir, {});
    const p = await c.newPage();
    await p.goto('about:blank');
    await c.close();
    return true;
  });

  console.log('--- done');
})().catch(e => { console.error('probe crashed:', e); process.exit(1); });
