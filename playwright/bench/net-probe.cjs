#!/usr/bin/env node
/*
 * Where does the extra ~4s go when the bench navigates to a PUBLIC host?
 *
 * bench "Test run" (tests/example.spec.ts -> https://playwright.dev/) is 14-15s on
 * alpine vs 10s on ubuntu/official. runtime-probe.cjs cannot see it: that one
 * serves from a local http server, so DNS and TLS to a real host are never
 * exercised. Summing its measured launch/goto/context deltas explains only
 * ~0.76s of the ~4-5s, so ~80% is somewhere it does not look.
 *
 * This splits a real navigation into its phases, twice over:
 *
 *   libc level     getent/curl — the resolver the C library gives us. musl and
 *                  glibc differ here: musl queries all nameservers in parallel,
 *                  has no search-domain retry ladder, and handles timeouts
 *                  differently.
 *   browser level  Navigation Timing from inside the page. Chromium and Firefox
 *                  ship their OWN DNS clients, so the libc number is a control,
 *                  not necessarily what the test pays. This is the one that has
 *                  to explain the gap.
 *
 * CommonJS + global playwright: same constraint as runtime-probe.cjs — ESM
 * ignores NODE_PATH and playwright is installed globally in these images.
 *
 * Usage: node net-probe.cjs --browser chromium --label alpine --iters 20 --out x.json
 */
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');

const URL_UNDER_TEST = process.env.PROBE_URL || 'https://playwright.dev/';
const HOST = new URL(URL_UNDER_TEST).host;

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const browserName = arg('browser', 'chromium');
const label = arg('label', 'unknown');
const iters = Number(arg('iters', '20'));
const out = arg('out', `net-${label}-${browserName}.json`);

function median(xs) {
  const s = [...xs].filter(v => typeof v === 'number' && !Number.isNaN(v)).sort((a, b) => a - b);
  if (!s.length) return null;
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// ---- libc level -------------------------------------------------------------
function curlPhases() {
  // Each iteration is a fresh process, so no in-process DNS cache carries over;
  // the OS/stub resolver cache still can, which is exactly what a test suite sees.
  const fmt = '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}';
  const rows = [];
  for (let i = 0; i < iters; i++) {
    try {
      const o = execFileSync('curl', ['-s', '-o', '/dev/null', '-w', fmt, URL_UNDER_TEST],
        { encoding: 'utf8', timeout: 30000 });
      const [dns, conn, tls, ttfb, total] = o.trim().split(/\s+/).map(Number);
      rows.push({ dns, conn, tls, ttfb, total });
    } catch { /* a failed sample is dropped, not zero-filled */ }
  }
  const pick = k => median(rows.map(r => r[k])) ;
  return {
    samples: rows.length,
    dns_ms: pick('dns') * 1000,
    connect_ms: (pick('conn') - pick('dns')) * 1000,
    tls_ms: (pick('tls') - pick('conn')) * 1000,
    ttfb_ms: (pick('ttfb') - pick('tls')) * 1000,
    total_ms: pick('total') * 1000,
  };
}

function getentMs() {
  const xs = [];
  for (let i = 0; i < iters; i++) {
    const t0 = process.hrtime.bigint();
    try { execFileSync('getent', ['hosts', HOST], { timeout: 10000 }); } catch { continue; }
    xs.push(Number(process.hrtime.bigint() - t0) / 1e6);
  }
  return median(xs);
}

// ---- browser level ----------------------------------------------------------
async function browserPhases() {
  const pw = require('playwright');
  const browser = await pw[browserName].launch();
  const rows = [];
  for (let i = 0; i < iters; i++) {
    // A fresh context per iteration so the browser's own DNS/TLS/session caches
    // do not make every run after the first free — the suite pays this per test.
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    try {
      await page.goto(URL_UNDER_TEST, { waitUntil: 'domcontentloaded', timeout: 60000 });
      const t = await page.evaluate(() => {
        const n = performance.getEntriesByType('navigation')[0];
        if (!n) return null;
        return {
          dns: n.domainLookupEnd - n.domainLookupStart,
          connect: n.connectEnd - n.connectStart,
          tls: n.secureConnectionStart ? n.connectEnd - n.secureConnectionStart : 0,
          ttfb: n.responseStart - n.requestStart,
          response: n.responseEnd - n.responseStart,
          total: n.responseEnd - n.startTime,
        };
      });
      if (t) rows.push(t);
    } catch { /* dropped */ }
    await ctx.close();
  }
  await browser.close();
  const pick = k => median(rows.map(r => r[k]));
  return {
    samples: rows.length,
    dns_ms: pick('dns'), connect_ms: pick('connect'), tls_ms: pick('tls'),
    ttfb_ms: pick('ttfb'), response_ms: pick('response'), total_ms: pick('total'),
  };
}

(async () => {
  const result = {
    label, browser: browserName, url: URL_UNDER_TEST, iters,
    libc: { getent_ms: getentMs(), curl: curlPhases() },
    browser_timing: await browserPhases(),
  };
  fs.writeFileSync(out, JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
})().catch(e => { console.error(e); process.exit(1); });
