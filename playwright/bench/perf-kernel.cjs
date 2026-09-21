#!/usr/bin/env node
/*
 * A steady-state loop for `perf record` to sample.
 *
 * Every no-rebuild candidate for chromium's residual has been eliminated by
 * static inspection, and the two live leads — `screenshot` 1.63x with about
 * three quarters of the overrun unattributed, and the ~12% geomean residual —
 * both need to be told WHERE the time goes rather than asked whether one more
 * hypothesis is true. A profiler answers that; a one-shot benchmark cannot,
 * because the interesting window is milliseconds long and buried under launch.
 *
 * So this script does one thing the other bench scripts deliberately do not: it
 * repeats a SINGLE kernel for a wall-clock duration, with the browser already
 * warm, and it announces when the steady state began. The workflow waits for
 * that announcement and only then starts sampling, so the profile contains the
 * kernel and not the launch.
 *
 * It reports timings too, but they are secondary — the same kernels are already
 * measured properly by runtime-probe.cjs and screenshot-encode-probe.cjs. What
 * is load-bearing here is `iterations` (so a profile can be normalised per
 * iteration) and the output digest (so both arms are provably doing identical
 * work, the way screenshot-encode-probe.cjs establishes it).
 *
 * Written for chromium and now driven for all three browsers (`--browser`):
 * the loop, the ready marker and the progress file are what the profiler
 * needs and none of it is engine-specific. The kernels named after
 * runtime-probe.cjs rows (goto_*, layout_reflow, click_force, locator_click,
 * eval_rtt, context_page, dom_churn, js_alloc, int_math, libm_fmod,
 * screenshot_png_text) copy that probe's page and actions verbatim, so a
 * profile taken here describes the row whose ratio is on record.
 */

const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

function median(values) {
  const s = [...values].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

// Lifted from screenshot-encode-probe.cjs on purpose: a canvas pattern has no
// fonts in it, so Alpine and Ubuntu rasterize the same bitmap and a byte
// difference in the PNG cannot be blamed on the input. A text page antialiases
// differently on the two distros, and a noisier bitmap is both bigger and
// slower to deflate — a codec-shaped result with no codec in it.
const CANVAS_HTML = `<!doctype html><meta charset="utf-8"><title>perf-kernel</title>
<style>html,body{margin:0;padding:0;background:#fff}canvas{display:block}</style>
<body><canvas id="c" width="1280" height="720"></canvas><script>
const g = document.getElementById('c').getContext('2d', { alpha: false });
g.fillStyle = '#ffffff';
g.fillRect(0, 0, 1280, 720);
for (let y = 0; y < 720; y += 40) {
  for (let x = 0; x < 1280; x += 40) {
    const v = ((x / 40) * 7 + (y / 40) * 13) % 6;
    g.fillStyle = ['#000000', '#ff0000', '#00ff00', '#0000ff', '#808080', '#ffffff'][v];
    g.fillRect(x, y, 40, 40);
  }
}
window.__ready = true;
</script></body>`;

/*
 * The page the CAMPAIGN's `screenshot` metric actually shoots: 800 rows of
 * antialiased text, from runtime-probe.cjs. It matters that this exists
 * separately from the canvas control, because on a hosted runner the canvas
 * shot lands ON the ~33 ms compositor cadence for BOTH arms — 1.01x wall while
 * the CPU underneath it is 1.26x. A kernel whose wall time is pinned to a frame
 * boundary cannot reproduce the number it is supposed to explain; this one is a
 * noisy enough bitmap to escape it.
 *
 * Its bytes are NOT comparable across arms: Alpine and Ubuntu antialias with
 * different fonts, so the two sides encode genuinely different pixels. That is
 * why the canvas control stays — it is the arm-to-arm digest check, and this
 * one is the timing.
 */
const TEXT_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>perf-kernel</title><style>
  body { margin: 0; font: 12px/1.2 sans-serif; }
  #pad div { padding: 1px 2px; border-bottom: 1px solid #eee; }
</style></head><body><div id="pad"></div>
<script>
  const pad = document.getElementById('pad');
  for (let i = 0; i < 800; i++) {
    const d = document.createElement('div');
    d.className = 'p' + (i % 16);
    d.textContent = 'row ' + i + ' lorem ipsum dolor sit amet';
    pad.appendChild(d);
  }
</script></body></html>`;

const DOM_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>perf-kernel</title><style>
  body { margin: 0; font: 12px/1.2 sans-serif; }
</style></head><body><div id="host"></div></body></html>`;

const REFLOW_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>perf-kernel</title><style>
  body { margin: 0; font: 12px/1.2 sans-serif; }
  #pad div { padding: 1px 2px; border-bottom: 1px solid #eee; }
  #layout { height: 20px; background: #ccc; }
</style></head><body>
<div id="layout"></div>
<div id="pad"></div>
<script>
  const pad = document.getElementById('pad');
  for (let i = 0; i < 800; i++) {
    const d = document.createElement('div');
    d.textContent = 'row ' + i;
    pad.appendChild(d);
  }
</script></body></html>`;

// runtime-probe.cjs's page, verbatim: 100 buttons for the click rows, the
// reflow target, a churn root and the 800-row pad. The click kernels need the
// buttons and the in-page kernels their ids, and a profile of a different
// page would answer a question nobody asked.
const BUTTONS = 100;
const PROBE_HTML = `<!doctype html>
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
  for (let i = 0; i < 800; i++) {
    const d = document.createElement('div');
    d.className = 'p' + (i % 16);
    d.textContent = 'row ' + i + ' lorem ipsum dolor sit amet';
    pad.appendChild(d);
  }
</script></body></html>`;

// Clicks every button once and asserts the page saw all of them, as
// runtime-probe.cjs does: a click that silently misses would turn the kernel
// into a measurement of nothing.
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
  return { tag: `clicks=${clicks}` };
}

// runtime-probe.cjs's self-timed in-page kernels, verbatim. Each returns the
// milliseconds IT measured, so the number never includes the evaluate() round
// trip, and a checksum that has to agree between the arms.
const IN_PAGE = {
  dom_churn: `() => {
    const root = document.getElementById('churn');
    const t0 = performance.now();
    for (let i = 0; i < 160000; i++) {
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
    for (let i = 0; i < 24000000; i++) {
      const o = { a: i, b: i + 1, c: 's' + (i & 255) };
      acc += o.a + o.b + o.c.length;
    }
    return { ms: performance.now() - t0, checksum: acc };
  }`,

  // Integer-only: Math.imul + |0 keep every value in int32, so this compiles
  // to integer machine code with NO libm call.
  int_math: `() => {
    const t0 = performance.now();
    let x = 1 | 0;
    for (let i = 0; i < 150000000; i++) {
      x = (Math.imul(x, 1664525) + 1013904223) | 0;
    }
    return { ms: performance.now() - t0, checksum: x };
  }`,

  // The ENGINE's double-modulo path, not libc's (issue #126): JSC and V8
  // serve `%` on doubles themselves; only firefox reaches a libm.
  libm_fmod: `() => {
    const t0 = performance.now();
    let x = 0;
    for (let i = 1; i < 9000000; i++) {
      x += (i * 2654435761) % 4294967291;
    }
    return { ms: performance.now() - t0, checksum: x };
  }`,
};

function inPageKernel(source) {
  return {
    page: PROBE_HTML,
    run: async (page) => {
      const r = await page.evaluate(`(${source})()`);
      return { ms: r.ms, tag: `checksum=${r.checksum}` };
    },
  };
}

// Same 800 rows / 300 forced reflows as chromium-gap-probe.cjs, so a profile
// taken here describes the kernel whose ratio is already on record rather than
// a differently-shaped one.
const ROWS = 800;
const ITERS = 300;

function layoutKernel(fill) {
  return `() => {
    const host = document.getElementById('host');
    host.textContent = '';
    for (let i = 0; i < ${ROWS}; i++) {
      const d = document.createElement('div');
      ${fill}
      host.appendChild(d);
    }
    void host.offsetHeight;
    const t0 = performance.now();
    let acc = 0;
    for (let i = 0; i < ${ITERS}; i++) {
      host.style.width = (400 + (i % 200)) + 'px';
      acc += host.offsetHeight;
    }
    const ms = performance.now() - t0;
    host.textContent = '';
    return { ms, checksum: acc };
  }`;
}

/*
 * `page` is which document the kernel needs; `run` returns `{ ms?, tag }` where
 * `tag` is whatever proves both arms did identical work — a digest for the
 * encoders, a checksum for the layout kernels.
 */
const KERNELS = {
  // The 1.63x. png_viewport is the only chromium screenshot cell stable enough
  // to carry a timing claim: the canvas control is bimodal across identical
  // runs (34.1 / 35.0 / 46.9 ms) and the 16x16 clip sits on the frame floor.
  screenshot_png: {
    page: CANVAS_HTML,
    run: async (page) => {
      const buf = await page.screenshot({ type: 'png' });
      return { tag: digestTag(buf) };
    },
  },

  // The campaign's own screenshot, on the campaign's own page. Not
  // digest-comparable across arms (different fonts), so `bytes_comparable` is
  // false and the report must not read the difference as "the arms did
  // different work" — here they legitimately did.
  screenshot_png_text: {
    page: TEXT_HTML,
    bytes_comparable: false,
    run: async (page) => {
      const buf = await page.screenshot({ type: 'png' });
      return { tag: digestTag(buf) };
    },
  },

  // The control that exonerated capture and readback: same compositing, same
  // pixel count, same transport, only the codec differs — and it lands on the
  // frame floor on BOTH sides. Two arms that agree here and diverge above have
  // localised the divergence to the encoder.
  screenshot_jpeg: {
    page: CANVAS_HTML,
    run: async (page) => {
      const buf = await page.screenshot({ type: 'jpeg', quality: 80 });
      return { tag: digestTag(buf) };
    },
  },

  // Compiled Blink C++ with no text in it. This is the kernel that survived
  // every elimination: ~1.6x on the box arm while JIT-emitted code is at parity.
  layout_boxonly: {
    page: DOM_HTML,
    run: async (page) => {
      const r = await page.evaluate(
        `(${layoutKernel("d.style.cssText = 'height:6px;margin:1px;background:#ddd';")})()`,
      );
      return { ms: r.ms, tag: `checksum=${r.checksum}` };
    },
  },

  // runtime-probe.cjs's `layout` row, which is NOT layout_boxonly and does not
  // measure the same thing. On one EPYC 7763 (run 34357346361) the campaign
  // row reads 1.52x while layout_boxonly reads 1.27x — same machine, same run,
  // so they are two costs rather than one measurement error. The difference is
  // shape: layout_boxonly does 300 reflows that each re-lay-out 800 children,
  // so it is bound by layout THROUGHPUT, while this one does 16,000 reflows of
  // a single bare div, so it is bound by the FIXED cost of entering a forced
  // synchronous reflow. 1.52x is chromium's worst row and nothing could
  // profile it until this kernel existed.
  layout_reflow: {
    page: REFLOW_HTML,
    run: async (page) => {
      const r = await page.evaluate(`(() => {
        const el = document.getElementById('layout');
        const t0 = performance.now();
        let acc = 0;
        for (let i = 0; i < 16000; i++) {
          el.style.width = (100 + (i % 200)) + 'px';
          acc += el.offsetHeight;
        }
        return { ms: performance.now() - t0, checksum: acc };
      })()`);
      return { ms: r.ms, tag: `checksum=${r.checksum}` };
    },
  },

  layout_text: {
    page: DOM_HTML,
    run: async (page) => {
      const r = await page.evaluate(
        `(${layoutKernel("d.style.cssText = 'margin:1px';\n"
          + "      d.textContent = 'row ' + i + ' lorem ipsum dolor sit amet "
          + "consectetur adipiscing elit sed do eiusmod';")})()`,
      );
      return { ms: r.ms, tag: `checksum=${r.checksum}` };
    },
  },
  /*
   * runtime-probe.cjs's `nav` rows: the residual that survived the tz fix.
   * 18 draws over four CPU models (2026-09-20, `main-6be10b3`) read goto_warm
   * 1.08-1.10 and goto_cold 1.08-1.13 on every one, while startup, dom_churn
   * and js_alloc sat at parity — so the gap is the document lifecycle
   * (parse, style, layout, paint, load), not V8 and not the process tree.
   * Same document and the same `waitUntil` as the probe row. The tag counts
   * the rows the inline script built, which is what proves both arms loaded
   * the same document rather than an error page.
   */
  goto_warm: {
    page: TEXT_HTML,
    run: async (page, { url }) => {
      await page.goto(url, { waitUntil: 'load' });
      const rows = await page.evaluate(
        'document.querySelectorAll("#pad div").length',
      );
      return { tag: `rows=${rows}` };
    },
  },

  // Fresh context per navigation: no HTTP cache, no compilation cache, plus
  // the context and page lifecycle the probe's goto_cold row also pays.
  goto_cold: {
    page: TEXT_HTML,
    run: async (_page, { url, browser }) => {
      const ctx = await browser.newContext();
      const page = await ctx.newPage();
      await page.goto(url, { waitUntil: 'load' });
      const rows = await page.evaluate(
        'document.querySelectorAll("#pad div").length',
      );
      await ctx.close();
      return { tag: `rows=${rows}` };
    },
  },
  // runtime-probe.cjs's `context_page`: the context + page lifecycle, paid
  // once per test under Playwright's default of one context per test.
  context_page: {
    page: PROBE_HTML,
    run: async (_page, { browser }) => {
      const ctx = await browser.newContext();
      const page = await ctx.newPage();
      await page.close();
      await ctx.close();
      return { tag: 'context_page' };
    },
  },

  // runtime-probe.cjs's `eval_rtt`: 500 trivial evaluates, the protocol
  // round trip every Playwright action pays.
  eval_rtt: {
    page: PROBE_HTML,
    run: async (page) => {
      let acc = 0;
      for (let i = 0; i < 500; i++) {
        acc += await page.evaluate(() => 1);
      }
      return { tag: `evals=${acc}` };
    },
  },

  // runtime-probe.cjs's two click rows. `locator_click` is frame-cadence
  // bound (the stability check waits for two identical frames); `click_force`
  // skips the waiting and is the CPU half of an action.
  locator_click: {
    page: PROBE_HTML,
    run: (page) => clickAll(page, {}),
  },
  click_force: {
    page: PROBE_HTML,
    run: (page) => clickAll(page, { force: true }),
  },

  dom_churn: inPageKernel(IN_PAGE.dom_churn),
  js_alloc: inPageKernel(IN_PAGE.js_alloc),
  int_math: inPageKernel(IN_PAGE.int_math),
  libm_fmod: inPageKernel(IN_PAGE.libm_fmod),

  /*
   * Not an in-page kernel: what `launch` measures IS the browser lifecycle, so
   * this one owns its browser instead of borrowing the shared page.
   *
   * The row reads 1.40-1.45x on every CPU model drawn and both arms scale
   * identically across them, so it is a constant per-launch cost. The startup
   * probe has since priced the part everyone assumed was the whole answer —
   * the DSO closure is +5.5 ms per exec, about 11 ms of a 48 ms gap — which
   * leaves the majority unattributed and no static candidate left to try.
   */
  launch: {
    standalone: true,
    run: async (browserType, browserArgs) => {
      const browser = await browserType.launch({ args: browserArgs });
      const version = browser.version();
      await browser.close();
      return { tag: `version=${version}` };
    },
  },
};

/*
 * Asks the shipped artifact what it is, as runtime-probe.cjs does. Chromium's
 * executablePath() names the full chrome, which the from-source artifact does
 * not ship, so the headless-shell sibling is looked up; webkit has no binary
 * that answers --version (executablePath() is pw_run.sh) and is read from the
 * so-name of the library the build produced. Never throws: a probe that dies
 * reading metadata loses the profile.
 */
function shippedVersion(browserType, browserName) {
  try {
    let exe = browserType.executablePath();
    if (browserName === 'chromium' && !fs.existsSync(exe)) {
      const root = path.dirname(path.dirname(path.dirname(exe)));
      const shell = fs.readdirSync(root).find((d) => /headless[_-]shell/.test(d));
      exe = path.join(root, shell, 'chrome-headless-shell-linux64',
        'chrome-headless-shell');
    }
    if (browserName === 'webkit') {
      const soRe = /^libWPEWebKit-[\d.]+\.so\.(\d+\.\d+\.\d+)$/;
      for (const entry of fs.readdirSync(path.dirname(exe), { recursive: true })) {
        const found = path.basename(entry).match(soRe);
        if (found) {
          return `libWPEWebKit ${found[1]}`;
        }
      }
      return 'unknown';
    }
    const out = execFileSync(exe, ['--version'], {
      encoding: 'utf8', timeout: 30000, stdio: ['ignore', 'pipe', 'pipe'],
    });
    return out.trim().split('\n')[0].trim() || 'unknown';
  } catch (err) {
    return `unknown (${err.message.split('\n')[0]})`;
  }
}

function digestTag(buf) {
  const sha = crypto.createHash('sha256').update(buf).digest('hex');
  return `${buf.length}B ${sha.slice(0, 12)}`;
}

async function main() {
  const target = arg('target', 'unknown');
  const kernelName = arg('kernel', 'screenshot_png');
  const seconds = Number(arg('seconds', '60'));
  const warmupSeconds = Number(arg('warmup', '4'));
  const outDir = arg('out', '.');
  const readyFile = arg('ready', '');

  const kernel = KERNELS[kernelName];
  if (!kernel) {
    throw new Error(`unknown kernel ${kernelName}; have `
      + `${Object.keys(KERNELS).join(', ')}`);
  }

  const browserName = arg('browser', 'chromium');
  const browserType = require('playwright')[browserName];
  if (!browserType) {
    throw new Error(`unknown browser "${browserName}"`);
  }
  // Space-separated extra browser flags. A build-config difference and a
  // runtime-flag difference produce the same profile, and only one of them
  // costs a 25-30 h rebuild — so the flag has to be testable first.
  const browserArgs = arg('browser-args', '').split(' ').filter(Boolean);
  // What the shipped binary says it is, beside what Playwright believes: for
  // webkit `browser.version()` is a playwright-core constant, the same on
  // both arms whatever was built, so the parity check below is vacuous there
  // and only the so-name read from the artifact can carry it.
  const binaryVersion = shippedVersion(browserType, browserName);

  // A standalone kernel launches its own browser every iteration, so it gets
  // no shared page, no server and no warm browser to hold open. It still needs
  // a version for the parity assert below, and one throwaway launch is the
  // cheapest place to read it.
  if (kernel.standalone) {
    const probe = await browserType.launch({ args: browserArgs });
    const version = probe.version();
    await probe.close();
    return loop({
      target, browserName, binaryVersion, kernelName, seconds, warmupSeconds,
      outDir, readyFile, browserArgs, browserVersion: version, kernel,
      runOnce: () => kernel.run(browserType, browserArgs),
    });
  }

  const browser = await browserType.launch({ args: browserArgs });
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 720 },
  });
  const page = await ctx.newPage();

  const server = http.createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(kernel.page);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;
  await page.goto(url, { waitUntil: 'load' });
  if (kernel.page === CANVAS_HTML) {
    await page.waitForFunction('window.__ready === true');
  }
  // The text page builds its rows in an inline script, so the shot has to wait
  // for layout to settle or the first frames capture a half-built document.
  if (kernel.page === TEXT_HTML) {
    await page.waitForFunction('document.querySelectorAll("#pad div").length'
      + ' === 800');
  }

  // Warmup is not politeness: the first screenshot pays lazy encoder init and
  // first-touch faults, and the first layout pass pays JIT and font init. A
  // profile that includes them describes startup, which is a different question
  // and already answered.
  await loop({
    target, browserName, binaryVersion, kernelName, seconds, warmupSeconds,
    outDir, readyFile, browserArgs, browserVersion: browser.version(), kernel,
    runOnce: () => kernel.run(page, { url, browser }),
    teardown: async () => {
      await ctx.close();
      await browser.close();
      await new Promise((resolve) => server.close(resolve));
    },
  });
}

async function loop({
  target, browserName, binaryVersion, kernelName, seconds, warmupSeconds,
  outDir, readyFile, browserArgs, browserVersion, kernel, runOnce, teardown,
}) {
  const warmupEnd = Date.now() + warmupSeconds * 1000;
  let tag = '';
  while (Date.now() < warmupEnd) {
    ({ tag } = await runOnce());
  }

  // Only now is the steady state real, so only now may sampling begin. The
  // caller polls for this file rather than guessing a delay, because the two
  // arms warm up at measurably different speeds and a fixed `perf --delay`
  // would sample a different phase on each side.
  if (readyFile) {
    fs.mkdirSync(path.dirname(readyFile), { recursive: true });
    fs.writeFileSync(readyFile, `${process.pid}\n`);
  }
  console.log(`[perf-kernel] steady state reached, looping ${kernelName} `
    + `for ${seconds}s (tag ${tag})`);

  // The iteration count, published after every iteration so the profiler
  // can bracket each of its passes (record, stat, sched, strace) with the
  // exact number of iterations that pass saw, instead of scaling one rate
  // over the whole loop. A rename rather than a write-in-place, so a reader
  // never sees a half-written number.
  const progressFile = path.join(outDir, `${target}-${kernelName}-progress`);
  fs.mkdirSync(outDir, { recursive: true });
  const publish = (n) => {
    fs.writeFileSync(`${progressFile}.tmp`, `${n}\n`);
    fs.renameSync(`${progressFile}.tmp`, progressFile);
  };
  publish(0);

  const samples = [];
  const end = Date.now() + seconds * 1000;
  while (Date.now() < end) {
    const t0 = process.hrtime.bigint();
    const r = await runOnce();
    const wall = Number(process.hrtime.bigint() - t0) / 1e6;
    tag = r.tag;
    // The in-page clock where the kernel has one: it excludes the protocol
    // round trip, which is a different metric with its own known gap.
    samples.push(r.ms === undefined ? wall : r.ms);
    publish(samples.length);
  }

  if (teardown) await teardown();

  const cpu = os.cpus()[0];
  const result = {
    target,
    browser: browserName,
    kernel: kernelName,
    seconds,
    iterations: samples.length,
    median_ms: Number(median(samples).toFixed(3)),
    min_ms: Number(Math.min(...samples).toFixed(3)),
    max_ms: Number(Math.max(...samples).toFixed(3)),
    tag,
    bytes_comparable: kernel.bytes_comparable !== false,
    browser_args: browserArgs,
    playwright_version: require('playwright/package.json').version,
    // The parity assert: two arms on different chromium versions are not a
    // comparison, and every version tag in this repo is derived from a pin
    // rather than read from the artifact unless something like this reads it.
    browser_version: browserVersion,
    binary_version: binaryVersion,
    libc: fs.existsSync('/lib/ld-musl-x86_64.so.1') ? 'musl' : 'glibc',
    runner: { cpu: cpu ? cpu.model : 'unknown', cores: os.cpus().length },
  };

  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(
    path.join(outDir, `${target}-${kernelName}-kernel.json`),
    `${JSON.stringify(result, null, 2)}\n`,
  );
  console.log(`[perf-kernel] ${target} ${kernelName}: `
    + `${result.iterations} iterations, median ${result.median_ms} ms, `
    + `tag ${tag}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
