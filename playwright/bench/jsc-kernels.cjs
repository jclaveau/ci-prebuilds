#!/usr/bin/env node
/*
 * Discriminates WHY our JSC runs the `libm_fmod` row 2.6x slower than
 * Playwright's on two builds that both report WebKit 26.5.
 *
 * What is already ruled out: libc. A counter preloaded into every WebKit
 * process recorded ZERO calls reaching `fmod`, with the original divisor and
 * with a prime one, so the row measures JSC's own double-modulo path and the
 * musl-vs-glibc reading of it is void (issue #126).
 *
 * That leaves the engine, and the engine has exactly two things that can
 * differ between two builds of the same source: which JIT tier compiled the
 * loop, and what the compiler did to the tier's own C++. Each kernel below
 * isolates one shape so the arms can be compared row by row rather than
 * through the single blended number:
 *
 *   mod_int_double  the shipped kernel — integral doubles, prime divisor
 *   mod_frac_double non-integral operands, which no integer path can serve
 *   mod_int32       the same modulo forced onto the int32 path
 *   fdiv            a double divide, to separate "double math" from "modulo"
 *   math_sqrt       an intrinsic, which every tier lowers to one instruction
 *   int_math        the imul control that already reads 1.00
 *
 * Arms come from the environment: WebKit reads JSC options from `JSC_*`, so
 * `-e JSC_useFTLJIT=false` on `docker run` reaches the WebProcess and the tier
 * hypothesis becomes a measurement instead of an argument. If official slows
 * to ours with FTL off, our build is not reaching FTL.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const browserName = arg('browser', 'webkit');
const target = arg('target', 'unknown');
const armLabel = arg('arm', 'default');
const reps = Number(arg('reps', '5'));
const outDir = arg('out', '.');

const KERNELS = {
  mod_int_double: `() => {
    const t0 = performance.now();
    let x = 0;
    for (let i = 1; i < 9000000; i++) {
      x += (i * 2654435761) % 4294967291;
    }
    return { ms: performance.now() - t0, checksum: x };
  }`,

  mod_frac_double: `() => {
    const t0 = performance.now();
    let x = 0;
    for (let i = 1; i < 9000000; i++) {
      x += (i * 1.7320508075688772) % 3.3166247903554;
    }
    return { ms: performance.now() - t0, checksum: x };
  }`,

  mod_int32: `() => {
    const t0 = performance.now();
    let x = 0;
    for (let i = 1; i < 9000000; i++) {
      x = (x + ((i * 65537) | 0) % 65521) | 0;
    }
    return { ms: performance.now() - t0, checksum: x };
  }`,

  fdiv: `() => {
    const t0 = performance.now();
    let x = 0;
    for (let i = 1; i < 9000000; i++) {
      x += (i * 2654435761) / 4294967291;
    }
    return { ms: performance.now() - t0, checksum: x };
  }`,

  math_sqrt: `() => {
    const t0 = performance.now();
    let x = 0;
    for (let i = 1; i < 9000000; i++) {
      x += Math.sqrt(i * 2654435761);
    }
    return { ms: performance.now() - t0, checksum: x };
  }`,

  int_math: `() => {
    const t0 = performance.now();
    let x = 0;
    for (let i = 1; i < 30000000; i++) {
      x = (Math.imul(x + i, 2654435761) ^ (x >>> 13)) | 0;
    }
    return { ms: performance.now() - t0, checksum: x };
  }`,
};

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

(async () => {
  const { [browserName]: browserType } = require('playwright');
  const browser = await browserType.launch();
  const page = await browser.newPage();

  const metrics = {};
  for (const [name, body] of Object.entries(KERNELS)) {
    const samples = [];
    for (let i = 0; i < reps; i++) {
      // `(body)()`, not `body`: a string argument is evaluated as an
      // EXPRESSION, so handing over the arrow function's source returns the
      // function itself and every kernel reports undefined. Same wrapping as
      // runtime-probe.cjs, which this file's kernels were lifted from.
      const { ms } = await page.evaluate(`(${body})()`);
      samples.push(ms);
    }
    metrics[name] = Math.round(median(samples) * 10) / 10;
    console.log(`${target}/${armLabel} ${name}: ${metrics[name]} ms`);
  }

  await browser.close();

  // The JSC options actually in force travel with the numbers: an arm whose
  // env never reached the WebProcess would otherwise be indistinguishable
  // from an arm where the option made no difference.
  const jscEnv = Object.fromEntries(
    Object.entries(process.env).filter(([k]) => k.startsWith('JSC_')),
  );

  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(
    path.join(outDir, `${target}-${armLabel}.json`),
    `${JSON.stringify({ target, arm: armLabel, browser: browserName, reps, cpu: os.cpus()[0].model, jscEnv, metrics }, null, 2)}\n`,
  );
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
