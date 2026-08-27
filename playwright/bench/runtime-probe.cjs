#!/usr/bin/env node
/*
 * Runtime perf probe — measures how fast the browsers we SHIP actually execute,
 * as opposed to `benchmark-playwright.yml` which measures cold start ("time until
 * tests begin"). Both matter; this one is the regression alarm for the browsers
 * built from source in `playwright-alpine-browsers.yml`.
 *
 * Why it exists: our chromium shipped with DCHECKs compiled in for months
 * (is_official_build=false silently flips Chromium's `dcheck_always_on` default),
 * which cost 9.3x on layout and 7.2x on DOM churn and made whole suites ~50%
 * slower on alpine. Nothing in CI could see it — every test was green, only the
 * wall clock moved. These kernels would each have caught it on the first run.
 *
 * Design notes:
 *   - CommonJS on purpose: `playwright` is a GLOBAL install in these images and
 *     ESM ignores NODE_PATH, so `import` could not resolve it.
 *   - Absolute milliseconds on a GHA runner are worthless (±20-30% between jobs).
 *     The consumer of this output is the RATIO against the `official` MCR control
 *     probed in the same workflow run — see the perf-report job.
 *   - Every kernel measures ONE subsystem. The `libm_fmod` kernel is split out
 *     explicitly because a `%` on a value past 2^53 compiles to an fmod() libm
 *     call: folding it into an "int math" kernel once made me report a libc gap
 *     as a JIT gap. The gap is real and large — but it runs the OTHER way from
 *     what this comment used to claim. Measured across firefox arms, musl is
 *     ~1.7x FASTER here (50 vs 85 ms, and 64 vs 110 ms), while a same-libc arm
 *     reads 0.99x. Anything reading this kernel as a musl penalty is reading it
 *     backwards.
 *   - In-page kernels time themselves with performance.now(), so protocol RTT is
 *     excluded from them and measured separately by `eval_rtt`.
 */

const http = require('node:http');
const os = require('node:os');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const PAD_NODES = 800; // layout weight — a trivial page hides layout regressions
const BUTTONS = 100; // sized to fit the viewport so clicks never pay for scrolling

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

function median(values) {
  const s = [...values].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

async function timed(fn) {
  const t0 = process.hrtime.bigint();
  const value = await fn();
  return { ms: Number(process.hrtime.bigint() - t0) / 1e6, value };
}

/*
 * Runs `fn` iters+1 times and drops the first result: the first iteration pays
 * JIT warmup, lazy font/GPU init and first-touch page faults, which is exactly
 * the noise we do not want in a regression signal.
 */
async function sample(iters, fn) {
  const samples = [];
  let last;
  for (let i = 0; i <= iters; i++) {
    const r = await timed(fn);
    last = r.value;
    if (i > 0) {
      samples.push(r.ms);
    }
  }
  return { median_ms: median(samples), samples, value: last };
}

/*
 * Clicks every button once and asserts the page saw all of them — a click that
 * silently misses would otherwise turn this into a measurement of nothing.
 */
async function clickAll(page, options) {
  await page.evaluate(() => {
    window.__clicks = 0;
  });
  for (let i = 0; i < BUTTONS; i++) {
    await page.locator(`#b${i}`).click(options);
  }
  const clicks = await page.evaluate(() => window.__clicks);
  if (clicks !== BUTTONS) {
    throw new Error(`registered ${clicks} clicks, expected ${BUTTONS}`);
  }
}

const PAGE_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>probe</title><style>
  body { margin: 0; font: 12px/1.2 sans-serif; }
  #pad div { padding: 1px 2px; border-bottom: 1px solid #eee; }
  #btns button { width: 58px; height: 18px; font-size: 9px; padding: 0; margin: 1px; }
  #layout { height: 20px; background: #ccc; }
</style></head><body>
<div id="btns"></div>
<div id="layout"></div>
<div id="churn"></div>
<div id="pad"></div>
<script>
  window.__clicks = 0;
  const btns = document.getElementById('btns');
  for (let i = 0; i < ${BUTTONS}; i++) {
    const b = document.createElement('button');
    b.id = 'b' + i;
    b.textContent = 'b' + i;
    b.addEventListener('click', () => { window.__clicks++; });
    btns.appendChild(b);
  }
  const pad = document.getElementById('pad');
  for (let i = 0; i < ${PAD_NODES}; i++) {
    const d = document.createElement('div');
    d.className = 'p' + (i % 16);
    d.textContent = 'row ' + i + ' lorem ipsum dolor sit amet';
    pad.appendChild(d);
  }
</script></body></html>`;

/*
 * In-page kernels. Each returns the milliseconds IT measured, so the number never
 * includes the evaluate() round trip. Keys are the metric names in the report.
 */
const KERNELS = {
  // Forced synchronous reflow: write a style, then read a layout-dependent
  // property. This is the DCHECK canary (was 9.3x) and also the cost Playwright
  // re-pays on every actionability poll.
  layout: `() => {
    const el = document.getElementById('layout');
    const t0 = performance.now();
    let acc = 0;
    for (let i = 0; i < 2000; i++) {
      el.style.width = (100 + (i % 200)) + 'px';
      acc += el.offsetHeight;
    }
    return { ms: performance.now() - t0, checksum: acc };
  }`,

  dom_churn: `() => {
    const root = document.getElementById('churn');
    const t0 = performance.now();
    for (let i = 0; i < 20000; i++) {
      const d = document.createElement('div');
      d.className = 'c' + (i & 7);
      d.textContent = 'n' + i;
      root.appendChild(d);
      if (i & 1) { root.removeChild(d); }
    }
    const ms = performance.now() - t0;
    const checksum = root.childElementCount;
    root.textContent = '';
    return { ms, checksum };
  }`,

  js_alloc: `() => {
    const t0 = performance.now();
    let acc = 0;
    for (let i = 0; i < 2000000; i++) {
      const o = { a: i, b: i + 1, c: 's' + (i & 255) };
      acc += o.a + o.b + o.c.length;
    }
    return { ms: performance.now() - t0, checksum: acc };
  }`,

  // Integer-only: Math.imul + |0 keep every value in int32, so this compiles to
  // integer machine code with NO libm call. Do not "simplify" it into a plain
  // multiply — the product would leave the int32 range and drag fmod in.
  int_math: `() => {
    const t0 = performance.now();
    let x = 1 | 0;
    for (let i = 0; i < 30000000; i++) {
      x = (Math.imul(x, 1664525) + 1013904223) | 0;
    }
    return { ms: performance.now() - t0, checksum: x };
  }`,

  // The libc gap, isolated on purpose: `%` on a double past 2^53 is an fmod()
  // call, so this number is the C library rather than the engine. Tracked so it
  // can never again contaminate a kernel that claims to measure the JIT. Sign
  // check before quoting it: musl measures ~1.7x FASTER than glibc here.
  libm_fmod: `() => {
    const t0 = performance.now();
    let x = 0;
    for (let i = 1; i < 3000000; i++) {
      x += (i * 2654435761) % 4294967296;
    }
    return { ms: performance.now() - t0, checksum: x };
  }`,
};

/*
 * executablePath() names the FULL chromium, but a headless launch runs
 * chrome-headless-shell and that is the only binary our from-source artifact
 * ships — so the path Playwright hands back does not exist here. Fall back to
 * the headless-shell sibling under the same browsers root.
 */
function resolveShippedBinary(exe) {
  if (fs.existsSync(exe)) {
    return exe;
  }
  // …/<root>/chromium-<rev>/chrome-linux64/chrome → three levels up is the root.
  const browsersRoot = path.dirname(path.dirname(path.dirname(exe)));
  for (const dir of fs.readdirSync(browsersRoot)) {
    if (!/headless[_-]shell/.test(dir)) {
      continue;
    }
    const shellDir = path.join(browsersRoot, dir);
    for (const entry of fs.readdirSync(shellDir, { recursive: true })) {
      if (path.basename(entry) === 'chrome-headless-shell') {
        return path.join(shellDir, entry);
      }
    }
  }
  throw new Error(`no runnable binary: ${exe} is absent and ${browsersRoot} has no headless shell`);
}

/*
 * Asks the shipped binary what it is, instead of trusting the image tag, the
 * workflow input, or Playwright. `browser.version()` reports what PLAYWRIGHT
 * believes: for WebKit it is a hardcoded playwright-core constant that passes
 * whatever WebKit we actually built, and a mislabelled artifact would report the
 * version it was tagged with rather than the one it contains.
 *
 * WebKit has no binary that answers --version (executablePath() is pw_run.sh),
 * so its engine version is read from the so-name of the library the build
 * produced — the same signal webkit/smoke/launch.cjs asserts.
 */
function binaryVersion(browserType, browserName) {
  const exe = resolveShippedBinary(browserType.executablePath());
  if (browserName === 'webkit') {
    const distDir = path.dirname(exe);
    const soRe = /^libWPEWebKit-[\d.]+\.so\.(\d+\.\d+\.\d+)$/;
    for (const entry of fs.readdirSync(distDir, { recursive: true })) {
      const found = path.basename(entry).match(soRe);
      if (found) {
        return `libWPEWebKit ${found[1]}`;
      }
    }
    return 'unknown';
  }
  const out = execFileSync(exe, ['--version'], {
    encoding: 'utf8',
    timeout: 30000,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return out.trim().split('\n')[0].trim() || 'unknown';
}

async function main() {
  const browserName = arg('browser', 'chromium');
  const target = arg('target', 'unknown');
  const outDir = arg('out', '.');

  const playwright = require('playwright');
  const browserType = playwright[browserName];
  if (!browserType) {
    throw new Error(`unknown browser "${browserName}"`);
  }

  // Before any measurement, so a run that benches the wrong artifact says so in
  // its first line rather than in a ratio nobody can attribute afterwards.
  const binVersion = binaryVersion(browserType, browserName);
  console.log(`${target}/${browserName} — binary reports: ${binVersion}`);

  const server = http.createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(PAGE_HTML);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;

  const metrics = {};

  // 1. launch — catches linker/fontconfig/dlopen regressions, and it is paid once
  // per worker (and again after every crash), so it is real suite time.
  metrics.launch = await sample(4, async () => {
    const b = await browserType.launch();
    await b.close();
  });

  const browser = await browserType.launch();
  const version = browser.version();

  // 2. context + page lifecycle — Playwright's default is one context per test,
  // so this scales with test COUNT.
  metrics.context_page = await sample(10, async () => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.close();
    await ctx.close();
  });

  // 3. cold navigation — fresh context each time, so no HTTP cache and no
  // warmed-up compilation cache.
  metrics.goto_cold = await sample(5, async () => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.goto(url, { waitUntil: 'load' });
    await ctx.close();
  });

  const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: 'load' });

  // 4. warm navigation — same page, everything cached: isolates the navigation
  // machinery from the download/parse cost measured above.
  metrics.goto_warm = await sample(10, async () => {
    await page.goto(url, { waitUntil: 'load' });
  });

  // 5. protocol round trip — 500 trivial evaluates. Multiplied by every single
  // Playwright action, so a driver/transport regression shows up here first.
  metrics.eval_rtt = await sample(3, async () => {
    for (let i = 0; i < 500; i++) {
      await page.evaluate(() => 1);
    }
  });

  // 6a. full actionability — what a real suite pays per action. Measured, this is
  // FRAME-CADENCE BOUND, not CPU bound: the stability check waits for the bounding
  // box to be identical across consecutive animation frames, so a healthy build
  // pins to a whole number of frames (chromium 33.3ms = 2 frames at 60Hz, webkit
  // 32.2, firefox 50.0) no matter which libc or CPU it runs on. That constant is
  // the point: it only moves when a build is too slow to hit its frame budget —
  // the DCHECK chromium sat at 1.5x here while every healthy engine was flat.
  metrics.locator_click = await sample(3, () => clickAll(page, {}));

  // 6b. the same clicks with `force`, which skips the visible/stable/enabled
  // waiting entirely. No frame quantization left, so this one moves with the
  // injected query + hit test + event dispatch — the CPU half of an action.
  metrics.click_force = await sample(3, () => clickAll(page, { force: true }));

  // 7. screenshot — CI configs capture these on failure and on retry. Viewport
  // rather than fullPage on purpose: that is Playwright's default, and a fullPage
  // shot of this document costs seconds per shot, which would dominate the probe.
  metrics.screenshot = await sample(3, async () => {
    for (let i = 0; i < 10; i++) {
      await page.screenshot({ type: 'png' });
    }
  });

  // 8..N. In-page kernels: one subsystem each, self-timed inside the page.
  for (const [name, source] of Object.entries(KERNELS)) {
    const samples = [];
    let checksum;
    for (let i = 0; i <= 3; i++) {
      // `evaluate` treats a string as an EXPRESSION, so the arrow function has to
      // be invoked in the source itself — passing it bare would resolve to the
      // (unserializable) function object and hand back undefined.
      const r = await page.evaluate(`(${source})()`);
      checksum = r.checksum;
      if (i > 0) {
        samples.push(r.ms);
      }
    }
    metrics[name] = { median_ms: median(samples), samples, checksum };
  }

  await ctx.close();
  await browser.close();
  await new Promise((resolve) => server.close(resolve));

  const cpu = os.cpus()[0];
  const result = {
    target,
    browser: browserName,
    browser_version: version,
    binary_version: binVersion,
    playwright_version: require('playwright/package.json').version,
    libc: fs.existsSync('/lib/ld-musl-x86_64.so.1') ? 'musl' : 'glibc',
    node: process.version,
    // Recorded to explain outliers, never to normalize: the runner class is the
    // reason ratios (not absolute ms) are the reportable number.
    runner: { cpu: cpu ? cpu.model : 'unknown', cores: os.cpus().length },
    metrics: Object.fromEntries(
      Object.entries(metrics).map(([k, v]) => [
        k,
        { median_ms: Number(v.median_ms.toFixed(3)), samples: v.samples.map((s) => Number(s.toFixed(3))) },
      ]),
    ),
  };

  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${target}-${browserName}.json`);
  fs.writeFileSync(outFile, `${JSON.stringify(result, null, 2)}\n`);

  const width = Math.max(...Object.keys(result.metrics).map((k) => k.length));
  console.log(`${target}/${browserName} — ${binVersion} (${result.libc}), playwright reports ${version}`);
  for (const [name, m] of Object.entries(result.metrics)) {
    console.log(`  ${name.padEnd(width)}  ${m.median_ms.toFixed(1).padStart(9)} ms`);
  }
  console.log(`wrote ${outFile}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
