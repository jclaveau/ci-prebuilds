#!/usr/bin/env node
/*
 * Is our bundled-dist layout what makes process creation slow on alpine?
 *
 * runtime-probe.cjs shows a sharp split for WebKit (the one clean comparison —
 * 26.4 on both sides, unlike Firefox which is 147 vs 150 and therefore
 * unattributable):
 *
 *     layout 1.01x   dom_churn 1.05x   js_alloc 1.09x   int_math 1.00x
 *     launch 1.32x   context_page 1.36x   click_force 1.33x
 *
 * Engine work is at parity; anything that spawns a process or does a protocol
 * round-trip is not. The suspect is our own packaging: bundle-dist flattens each
 * browser's .so closure next to the binary with RPATH=$ORIGIN, so every process
 * start resolves a large private library set instead of the system's.
 *
 * Discriminator (the same one that root-caused the GTK self-recursion): RUNPATH
 * loses to LD_LIBRARY_PATH, so pointing it at /usr/lib forces the apk-provided
 * libraries and bypasses the bundle. If launch gets faster, the bundle is the
 * cost and the fix is packaging, not the engine.
 *
 *   bundled   as shipped
 *   system    LD_LIBRARY_PATH=/usr/lib
 *
 * `context_page` is measured too: WebKit spawns a WebProcess per context, so if
 * spawn cost is the story it should move with launch and not on its own.
 *
 * Usage: node spawn-probe.cjs --browser webkit --iters 8 --out spawn.json
 */
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const browserName = arg('browser', 'webkit');
const iters = Number(arg('iters', '8'));
const out = arg('out', `spawn-${browserName}.json`);

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  if (!s.length) return null;
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// Static picture of what each process start has to resolve.
function bundleShape() {
  const pw = require('playwright');
  let exe = null;
  try { exe = pw[browserName].executablePath(); } catch { /* ignore */ }
  if (!exe || !fs.existsSync(exe)) return { executable: exe, so_count: null, dir_mb: null };
  const dir = path.dirname(exe);
  let so = 0, bytes = 0;
  const walk = d => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else {
        const st = fs.statSync(p);
        bytes += st.size;
        if (/\.so(\.|$)/.test(e.name)) so++;
      }
    }
  };
  try { walk(dir); } catch { /* ignore */ }
  let ldd_lines = null;
  try {
    ldd_lines = execFileSync('ldd', [exe], { encoding: 'utf8' }).trim().split('\n').length;
  } catch { /* musl ldd exits non-zero on some binaries */ }
  return { executable: exe, dir, so_count: so, dir_mb: +(bytes / 1048576).toFixed(1), ldd_lines };
}

// The measurement runs in a CHILD process so LD_LIBRARY_PATH is set before the
// dynamic linker starts — mutating process.env in-process is too late for libs
// the browser's own children load.
const CHILD = `
const pw = require('playwright');
(async () => {
  const name = process.env.PROBE_BROWSER, iters = Number(process.env.PROBE_ITERS);
  const launches = [], contexts = [];
  for (let i = 0; i <= iters; i++) {           // +1 warmup, dropped
    let t0 = process.hrtime.bigint();
    const b = await pw[name].launch();
    const launchMs = Number(process.hrtime.bigint() - t0) / 1e6;
    t0 = process.hrtime.bigint();
    const c = await b.newContext();
    await c.newPage();
    const ctxMs = Number(process.hrtime.bigint() - t0) / 1e6;
    await b.close();
    if (i > 0) { launches.push(launchMs); contexts.push(ctxMs); }
  }
  console.log(JSON.stringify({ launches, contexts }));
})().catch(e => { console.error(e); process.exit(1); });
`;

function measure(mode) {
  const env = { ...process.env, PROBE_BROWSER: browserName, PROBE_ITERS: String(iters) };
  if (mode === 'system') env.LD_LIBRARY_PATH = '/usr/lib';
  const script = path.join(require('node:os').tmpdir(), `spawn-child-${process.pid}.cjs`);
  fs.writeFileSync(script, CHILD);
  try {
    const o = execFileSync(process.execPath, [script], { env, encoding: 'utf8', timeout: 600000 });
    const { launches, contexts } = JSON.parse(o.trim().split('\n').pop());
    return { launch_ms: median(launches), context_page_ms: median(contexts), samples: launches.length };
  } catch (e) {
    // A failure here is a RESULT, not a crash: forcing system libs can legitimately
    // break a browser whose bundle carries versions the system does not have.
    return { error: String(e.message || e).slice(0, 300) };
  } finally {
    fs.rmSync(script, { force: true });
  }
}

const result = { browser: browserName, iters, shape: bundleShape() };
for (const mode of ['bundled', 'system']) result[mode] = measure(mode);
if (result.bundled?.launch_ms && result.system?.launch_ms) {
  result.verdict = {
    launch_ratio_system_over_bundled: +(result.system.launch_ms / result.bundled.launch_ms).toFixed(3),
    context_ratio_system_over_bundled:
      +(result.system.context_page_ms / result.bundled.context_page_ms).toFixed(3),
    note: 'below 1.0 means forcing system libs is FASTER, i.e. the bundle costs us',
  };
}
fs.writeFileSync(out, JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
