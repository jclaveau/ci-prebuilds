#!/usr/bin/env node
/**
 * Chromium tracing of the runtime-probe scenarios: which Blink/V8/cc phases
 * hold the time, per scenario, so a ratio against official can be read per
 * subsystem (Layout vs UpdateLayoutTree vs Paint vs FunctionCall ...) instead
 * of per row. Same page and kernels as runtime-probe.cjs.
 *
 *   node trace-probe.cjs --target alpine --out /out [--iters 3]
 *
 * Writes <out>/<target>-trace.json: per scenario the wall time and, per trace
 * event name on the renderer main thread, the SELF time (children subtracted)
 * and the inclusive time, in ms.
 */
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const { PAGE_HTML, KERNELS, clickAll } = require('./runtime-probe.cjs');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const CATEGORIES = [
  'devtools.timeline', 'disabled-by-default-devtools.timeline', 'blink',
  'blink.user_timing', 'v8.execute', 'toplevel', 'cc', 'loading',
];

/** Self and inclusive time per event name, over every thread; B/E pairs folded into X. */
function aggregate(traceEvents) {
  const byThread = new Map();
  for (const e of traceEvents) {
    if (e.ph !== 'X' && e.ph !== 'B' && e.ph !== 'E') continue;
    const key = `${e.pid}:${e.tid}`;
    if (!byThread.has(key)) byThread.set(key, []);
    byThread.get(key).push(e);
  }
  const self = {};
  const incl = {};
  const add = (map, name, v) => { map[name] = (map[name] || 0) + v; };
  for (const events of byThread.values()) {
    events.sort((a, b) => a.ts - b.ts || (a.ph === 'E') - (b.ph === 'E'));
    const stack = [];
    const open = [];
    const close = (frame, end) => {
      const dur = end - frame.ts;
      add(incl, frame.name, dur);
      add(self, frame.name, dur - frame.children);
      if (stack.length) stack[stack.length - 1].children += dur;
    };
    for (const e of events) {
      const ts = e.ts;
      while (stack.length && stack[stack.length - 1].end !== undefined && stack[stack.length - 1].end <= ts) {
        const f = stack.pop();
        close(f, f.end);
      }
      if (e.ph === 'X') {
        const frame = { name: e.name, ts, end: ts + (e.dur || 0), children: 0 };
        stack.push(frame);
      } else if (e.ph === 'B') {
        const frame = { name: e.name, ts, end: undefined, children: 0 };
        stack.push(frame);
        open.push(frame);
      } else if (e.ph === 'E') {
        const i = stack.map((f) => f.name).lastIndexOf(e.name);
        if (i === -1) continue;
        // pop everything above, closing X frames at their own end
        while (stack.length > i + 1) {
          const f = stack.pop();
          close(f, f.end === undefined ? ts : f.end);
        }
        const f = stack.pop();
        close(f, ts);
      }
    }
    while (stack.length) {
      const f = stack.pop();
      close(f, f.end === undefined ? f.ts : f.end);
    }
  }
  const toMs = (m) => Object.fromEntries(Object.entries(m).map(([k, v]) => [k, v / 1000]));
  return { self_ms: toMs(self), inclusive_ms: toMs(incl) };
}

async function traced(browser, page, fn, iters) {
  await browser.startTracing(page, { screenshots: false, categories: CATEGORIES });
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < iters; i++) await fn();
  const wall = Number(process.hrtime.bigint() - t0) / 1e6;
  const buf = await browser.stopTracing();
  const trace = JSON.parse(buf.toString('utf8'));
  const events = Array.isArray(trace) ? trace : trace.traceEvents;
  return { iters, wall_ms: wall, events: events.length, ...aggregate(events) };
}

async function main() {
  const target = arg('target', 'unknown');
  const outDir = arg('out', '.');
  const iters = Number(arg('iters', '3'));
  const { chromium } = require('playwright');

  const server = http.createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(PAGE_HTML);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  const page = await ctx.newPage();
  await page.goto(url, { waitUntil: 'load' });

  const scenarios = {
    goto_warm: async () => { for (let i = 0; i < 10; i++) await page.goto(url, { waitUntil: 'load' }); },
    click_force: () => clickAll(page, { force: true }),
    screenshot: async () => { for (let i = 0; i < 10; i++) await page.screenshot({ type: 'png' }); },
  };
  for (const [name, source] of Object.entries(KERNELS)) {
    scenarios[name] = () => page.evaluate(`(${source})()`);
  }

  const result = { target, version: browser.version(), iters, scenarios: {} };
  for (const [name, fn] of Object.entries(scenarios)) {
    await fn(); // warm, untraced
    result.scenarios[name] = await traced(browser, page, fn, iters);
    const r = result.scenarios[name];
    const top = Object.entries(r.self_ms).sort((a, b) => b[1] - a[1]).slice(0, 8)
      .map(([k, v]) => `${k} ${v.toFixed(0)}`).join(', ');
    console.log(`${target} ${name}: wall ${r.wall_ms.toFixed(0)} ms, ${r.events} events; self: ${top}`);
  }

  await ctx.close();
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${target}-trace.json`);
  fs.writeFileSync(outFile, JSON.stringify(result));
  console.log(`wrote ${outFile}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
