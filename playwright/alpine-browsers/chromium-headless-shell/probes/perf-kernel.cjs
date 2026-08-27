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
 */

const crypto = require('node:crypto');
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

const DOM_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>perf-kernel</title><style>
  body { margin: 0; font: 12px/1.2 sans-serif; }
</style></head><body><div id="host"></div></body></html>`;

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
};

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

  const playwright = require('playwright');
  // Space-separated extra chromium flags. A build-config difference and a
  // runtime-flag difference produce the same profile, and only one of them
  // costs a 25-30 h rebuild — so the flag has to be testable first.
  const browserArgs = arg('browser-args', '').split(' ').filter(Boolean);
  const browser = await playwright.chromium.launch({ args: browserArgs });
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 720 },
  });
  const page = await ctx.newPage();

  const server = http.createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(kernel.page);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  await page.goto(`http://127.0.0.1:${server.address().port}/`, {
    waitUntil: 'load',
  });
  if (kernel.page === CANVAS_HTML) {
    await page.waitForFunction('window.__ready === true');
  }

  // Warmup is not politeness: the first screenshot pays lazy encoder init and
  // first-touch faults, and the first layout pass pays JIT and font init. A
  // profile that includes them describes startup, which is a different question
  // and already answered.
  const warmupEnd = Date.now() + warmupSeconds * 1000;
  let tag = '';
  while (Date.now() < warmupEnd) {
    ({ tag } = await kernel.run(page));
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

  const samples = [];
  const end = Date.now() + seconds * 1000;
  while (Date.now() < end) {
    const t0 = process.hrtime.bigint();
    const r = await kernel.run(page);
    const wall = Number(process.hrtime.bigint() - t0) / 1e6;
    tag = r.tag;
    // The in-page clock where the kernel has one: it excludes the protocol
    // round trip, which is a different metric with its own known gap.
    samples.push(r.ms === undefined ? wall : r.ms);
  }

  await ctx.close();
  await browser.close();
  await new Promise((resolve) => server.close(resolve));

  const cpu = os.cpus()[0];
  const result = {
    target,
    kernel: kernelName,
    seconds,
    iterations: samples.length,
    median_ms: Number(median(samples).toFixed(3)),
    min_ms: Number(Math.min(...samples).toFixed(3)),
    max_ms: Number(Math.max(...samples).toFixed(3)),
    tag,
    browser_args: browserArgs,
    playwright_version: require('playwright/package.json').version,
    // The parity assert: two arms on different chromium versions are not a
    // comparison, and every version tag in this repo is derived from a pin
    // rather than read from the artifact unless something like this reads it.
    browser_version: browser.version(),
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
