#!/usr/bin/env node
/*
 * Splits `page.screenshot()` into the three costs it actually pays, because the
 * runtime probe reports one number for all of them and that number is 0.68x on
 * our musl Firefox (32.5 ms/shot vs 22.2 ms official, samples non-overlapping).
 *
 * The three suspects, and the variable that separates them:
 *
 *   encode     png vs jpeg — same capture, same transport, different codec.
 *              A gap that lives only in png is a deflate gap.
 *   capture    full viewport vs a 16x16 clip — a clip still composites and
 *              reads back, but encodes ~3500x fewer pixels. A gap that survives
 *              the clip is not in the codec.
 *   transport  the per-shot floor both of the above share.
 *
 * Byte counts are recorded next to every timing: they are deterministic where
 * a millisecond is not, so a size difference between two builds proves the
 * encoders differ even when the timings could be argued as runner noise.
 *
 * Reads the version off the binary for the same reason runtime-probe.cjs does.
 */
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const PAD_NODES = 800;

function median(values) {
  const s = [...values].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const PAGE_HTML = `<!doctype html><meta charset="utf-8"><title>probe</title>
<style>body{font:14px system-ui;margin:0}.pad{padding:2px;border:1px solid #ccc}</style>
<body><div id="host">${'<div class="pad">x</div>'.repeat(PAD_NODES)}</div></body>`;

/*
 * A control whose pixels cannot differ between the two images. The text page
 * above renders with whatever fonts the distro ships, so Alpine and Ubuntu
 * antialias it differently — and a noisier bitmap is both larger and slower to
 * deflate, which would produce a codec-shaped result with no codec difference
 * in it. This page draws a deterministic pattern into a canvas: no fonts, no
 * layout, integer coordinates, flat fills. If the two sides still disagree on
 * the PNG bytes here, the difference is not the input.
 */
const CANVAS_HTML = `<!doctype html><meta charset="utf-8"><title>probe-canvas</title>
<style>html,body{margin:0;padding:0;background:#fff}canvas{display:block}</style>
<body><canvas id="c" width="1280" height="720"></canvas><script>
const g = document.getElementById('c').getContext('2d', { alpha: false });
g.fillStyle = '#ffffff';
g.fillRect(0, 0, 1280, 720);
for (let y = 0; y < 720; y += 40) {
  for (let x = 0; x < 1280; x += 40) {
    // Deterministic, no Math.random and no time: the same bitmap every run.
    const v = ((x / 40) * 7 + (y / 40) * 13) % 6;
    g.fillStyle = ['#000000', '#ff0000', '#00ff00', '#0000ff', '#808080', '#ffffff'][v];
    g.fillRect(x, y, 40, 40);
  }
}
window.__ready = true;
</script></body>`;

async function measure(page, label, options, iters = 12) {
  const times = [];
  let bytes = 0;
  let digest = '';
  for (let i = 0; i <= iters; i++) {
    const t0 = process.hrtime.bigint();
    const buf = await page.screenshot(options);
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    // Drop the first: it pays lazy encoder init and first-touch faults.
    if (i > 0) {
      times.push(ms);
    }
    bytes = buf.length;
    digest = crypto.createHash('sha256').update(buf).digest('hex').slice(0, 16);
  }
  return { label, median_ms: Number(median(times).toFixed(3)), bytes, digest, samples: times.map((t) => Number(t.toFixed(3))) };
}

async function main() {
  const target = arg('target', 'unknown');
  const outDir = arg('out', '.');
  const browserName = arg('browser', 'firefox');

  const playwright = require('playwright');
  const browserType = playwright[browserName];

  const exe = browserType.executablePath();
  const { execFileSync } = require('node:child_process');
  let binVersion = 'unknown';
  try {
    binVersion = execFileSync(exe, ['--version'], { encoding: 'utf8', timeout: 30000 }).trim().split('\n')[0];
  } catch (e) {
    binVersion = `unreadable (${String(e.message).split('\n')[0]})`;
  }
  console.log(`${target}/${browserName} — binary reports: ${binVersion}`);

  const server = http.createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(PAGE_HTML);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;

  const browser = await browserType.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: 'load' });

  const results = [];
  results.push(await measure(page, 'png_viewport', { type: 'png' }));
  results.push(await measure(page, 'jpeg_q80_viewport', { type: 'jpeg', quality: 80 }));
  results.push(await measure(page, 'png_clip_16x16', { type: 'png', clip: { x: 0, y: 0, width: 16, height: 16 } }));
  results.push(await measure(page, 'jpeg_q80_clip_16x16', { type: 'jpeg', quality: 80, clip: { x: 0, y: 0, width: 16, height: 16 } }));

  const canvasPage = await ctx.newPage();
  await canvasPage.setContent(CANVAS_HTML, { waitUntil: 'load' });
  await canvasPage.waitForFunction('window.__ready === true');
  results.push(await measure(canvasPage, 'png_canvas_control', { type: 'png' }));
  results.push(await measure(canvasPage, 'jpeg_q80_canvas_control', { type: 'jpeg', quality: 80 }));
  await canvasPage.close();

  await ctx.close();
  await browser.close();
  await new Promise((resolve) => server.close(resolve));

  const out = {
    target,
    browser: browserName,
    binary_version: binVersion,
    playwright_version: require('playwright/package.json').version,
    libc: fs.existsSync('/lib/ld-musl-x86_64.so.1') ? 'musl' : 'glibc',
    results,
  };
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, `${target}-screenshot.json`), `${JSON.stringify(out, null, 2)}\n`);

  for (const r of results) {
    console.log(`  ${r.label.padEnd(22)} ${r.median_ms.toFixed(1).padStart(8)} ms  ${String(r.bytes).padStart(8)} B  sha=${r.digest}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
