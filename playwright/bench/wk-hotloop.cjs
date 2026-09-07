#!/usr/bin/env node
/*
 * Runs ONE runtime-probe kernel continuously so a profiler has something to
 * sample, and prints the pids it wants profiled.
 *
 * Why it exists: `click_force` 1.24, `eval_rtt` 1.13 and `goto_cold` 1.11 have
 * no candidate cause left. ThinLTO barely moves them, and the stack protector —
 * which looked obvious at 233 941 canary loads against official's zero — moved
 * nothing at all when it was removed and measured. Static candidates are
 * exhausted, so the next instrument is a differential profile, the same way the
 * chromium screenshot row was cracked after its own static list ran out.
 *
 * The kernels are duplicated from runtime-probe.cjs deliberately rather than
 * imported: that file measures and reports, and it would have to grow a
 * profiling mode to be reused here. What must not drift is the WORKLOAD, so the
 * page and the actions are copied verbatim — a profile of a different page
 * would answer a question nobody asked.
 *
 * usage: wk-hotloop.cjs --browser webkit --kernel click_force --seconds 45
 */

const http = require('node:http');
const fs = require('node:fs');

const PAD_NODES = 800;
const BUTTONS = 100;

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const browserName = arg('browser', 'webkit');
const kernel = arg('kernel', 'click_force');
const seconds = Number(arg('seconds', '45'));
const pidFile = arg('pidfile', '');

const PAGE_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>hotloop</title><style>
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

(async () => {
  const { [browserName]: browserType } = require('playwright');

  const server = http.createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(PAGE_HTML);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;

  const browser = await browserType.launch();
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto(url);

  // The pids are the whole point: perf attaches from the HOST, and the process
  // doing the work is the WebProcess, not this driver.
  if (pidFile) {
    fs.writeFileSync(pidFile, `${process.pid}\n`);
  }
  console.log(`hotloop ready: kernel=${kernel} driver_pid=${process.pid} url=${url}`);

  const deadline = Date.now() + seconds * 1000;
  let rounds = 0;
  while (Date.now() < deadline) {
    if (kernel === 'click_force' || kernel === 'locator_click') {
      const options = kernel === 'click_force' ? { force: true } : {};
      for (let i = 0; i < BUTTONS; i++) {
        await page.locator(`#b${i}`).click(options);
      }
    } else if (kernel === 'eval_rtt') {
      for (let i = 0; i < 500; i++) {
        await page.evaluate(() => 1);
      }
    } else if (kernel === 'goto_cold') {
      const fresh = await browser.newContext();
      const p = await fresh.newPage();
      await p.goto(url);
      await fresh.close();
    } else if (kernel === 'screenshot') {
      for (let i = 0; i < 10; i++) {
        await page.screenshot({ type: 'png' });
      }
    } else {
      throw new Error(`unknown kernel: ${kernel}`);
    }
    rounds++;
  }

  console.log(`hotloop done: rounds=${rounds}`);
  await browser.close();
  server.close();
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
