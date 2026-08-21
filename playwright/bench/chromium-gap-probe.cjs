#!/usr/bin/env node
/*
 * Partitions the ~1.3x geomean / 1.89x layout gap that survives BOTH chromium
 * perf knobs (PGO and ThinLTO each close about a third of it, neither reaches
 * parity with PW's official build).
 *
 * Three questions, one script, because they share a page and a browser:
 *
 *   layout_boxonly vs layout_text
 *     The same forced-reflow loop over a subtree with no text at all, and over
 *     one that is nothing but text. Our alpine build links fontconfig,
 *     freetype and harfbuzz unbundled (`replace_gn_files.py
 *     --system-libraries`) where official bundles its own; if that is the
 *     cost, it lands on the text arm and leaves the box arm flat.
 *
 *   text_metrics
 *     Advance widths of fixed strings, to three decimals. Deterministic where
 *     a millisecond is not: two builds that measure the same string to the
 *     same width are shaping it with the same face and the same rasterizer,
 *     which answers the font question without comparing package lists. A
 *     width difference also invalidates the timing comparison above, because
 *     the two sides would not be laying out the same boxes.
 *
 *   (the third probe, PartitionAlloc symbols, is shell-side in the workflow —
 *    it inspects the binary, not the running page)
 *
 * Deliberately NOT part of runtime-probe.cjs: that script is the regression
 * alarm whose kernels are compared across runs going back months, and adding
 * kernels to it would be fine but changing its `layout` would not. Keeping the
 * investigation separate means neither constrains the other.
 */

const http = require('node:http');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');

// Matched to runtime-probe.cjs's PAD_NODES so the text arm is the same weight
// of document as the kernel whose gap sent us here.
const ROWS = 800;

// 300, not the 2000 of runtime-probe's `layout`: each iteration here re-lays
// out all 800 children rather than one empty div, so 2000 would run into tens
// of seconds on the slow side and blow the job's budget.
const ITERS = 300;

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

function median(values) {
  const s = [...values].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

const PAGE_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>gap-probe</title><style>
  body { margin: 0; font: 12px/1.2 sans-serif; }
</style></head><body><div id="host"></div></body></html>`;

/*
 * Both arms share this shape so the only variable between them is whether the
 * children carry text. `fill` writes the children; everything after it is
 * identical source.
 */
function layoutKernel(fill) {
  return `() => {
    const host = document.getElementById('host');
    host.textContent = '';
    for (let i = 0; i < ${ROWS}; i++) {
      const d = document.createElement('div');
      ${fill}
      host.appendChild(d);
    }
    // Flush the construction out of the timed region.
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

const KERNELS = {
  /*
   * TypedArray bulk moves and fills, which V8 lowers to the platform memmove
   * and memset once the run is long enough to be worth the call. 64 KiB per
   * operation is well past that threshold and is also the order of a layout
   * pass's own buffer traffic.
   *
   * Here because the native bench (libc-string-bench.c) sizes musl's routines
   * against glibc's in isolation, and an isolated microbenchmark has already
   * been wrong about magnitude once — this says whether the browser process
   * actually pays the difference.
   */
  typed_array_move: `() => {
    const buf = new Uint8Array(1 << 20);
    buf.fill(7);
    const t0 = performance.now();
    let acc = 0;
    for (let i = 0; i < 4000; i++) {
      buf.copyWithin(0, 1 << 16, 1 << 17);
      acc += buf[i & 0xffff];
    }
    return { ms: performance.now() - t0, checksum: acc };
  }`,

  typed_array_fill: `() => {
    const buf = new Uint8Array(1 << 20);
    const t0 = performance.now();
    let acc = 0;
    for (let i = 0; i < 4000; i++) {
      buf.fill(i & 0xff, 0, 1 << 16);
      acc += buf[0];
    }
    return { ms: performance.now() - t0, checksum: acc };
  }`,

  // Fixed-height boxes, no text node anywhere: the width change still dirties
  // and re-lays-out all 800 children, but nothing is shaped or measured.
  layout_boxonly: layoutKernel(
    "d.style.cssText = 'height:6px;margin:1px;background:#ddd';",
  ),

  // Same 800 children, same loop, text added. The width change forces every
  // row to re-wrap, so this arm pays shaping on top of box layout.
  layout_text: layoutKernel(
    "d.style.cssText = 'margin:1px';\n" +
    "      d.textContent = 'row ' + i + ' lorem ipsum dolor sit amet " +
    "consectetur adipiscing elit sed do eiusmod';",
  ),
};

/*
 * Widths rather than a font name: the resolved family is what fontconfig was
 * ASKED for, the advance width is what the rasterizer actually did. A build
 * can resolve `sans-serif` to a same-named face and still shape it
 * differently.
 */
const TEXT_METRICS = `() => {
  const c = document.createElement('canvas').getContext('2d');
  const sample = 'row 123 lorem ipsum dolor sit amet consectetur';
  const out = {};
  for (const family of ['sans-serif', 'serif', 'monospace']) {
    c.font = '12px ' + family;
    out[family] = Number(c.measureText(sample).width.toFixed(3));
  }
  // The DOM path too: canvas and layout can disagree, and it is layout that
  // the kernels above are timing.
  const span = document.createElement('span');
  span.style.cssText = 'font:12px sans-serif;white-space:pre';
  span.textContent = sample;
  document.body.appendChild(span);
  out.dom_span_px = Number(span.getBoundingClientRect().width.toFixed(3));
  span.remove();
  out.device_pixel_ratio = window.devicePixelRatio;
  return out;
}`;

async function main() {
  const target = arg('target', 'unknown');
  const outDir = arg('out', '.');

  const playwright = require('playwright');
  const browser = await playwright.chromium.launch();
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 720 },
  });
  const page = await ctx.newPage();

  const server = http.createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(PAGE_HTML);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  await page.goto(`http://127.0.0.1:${server.address().port}/`, {
    waitUntil: 'load',
  });

  const metrics = {};
  for (const [name, source] of Object.entries(KERNELS)) {
    const samples = [];
    let checksum;
    for (let i = 0; i <= 4; i++) {
      const r = await page.evaluate(`(${source})()`);
      checksum = r.checksum;
      // Drop the first: JIT warmup and lazy font init.
      if (i > 0) {
        samples.push(r.ms);
      }
    }
    metrics[name] = {
      median_ms: Number(median(samples).toFixed(3)),
      samples: samples.map((s) => Number(s.toFixed(3))),
      checksum,
    };
  }

  const text = await page.evaluate(`(${TEXT_METRICS})()`);

  await ctx.close();
  await browser.close();
  await new Promise((resolve) => server.close(resolve));

  const cpu = os.cpus()[0];
  const result = {
    target,
    playwright_version: require('playwright/package.json').version,
    libc: fs.existsSync('/lib/ld-musl-x86_64.so.1') ? 'musl' : 'glibc',
    runner: { cpu: cpu ? cpu.model : 'unknown', cores: os.cpus().length },
    metrics,
    text_metrics: text,
  };

  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${target}-gap.json`);
  fs.writeFileSync(outFile, `${JSON.stringify(result, null, 2)}\n`);

  console.log(`${target} (${result.libc})`);
  for (const [name, m] of Object.entries(metrics)) {
    console.log(`  ${name.padEnd(16)} ${m.median_ms.toFixed(1).padStart(9)} ms`);
  }
  console.log(`  text_metrics     ${JSON.stringify(text)}`);
  console.log(`wrote ${outFile}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
