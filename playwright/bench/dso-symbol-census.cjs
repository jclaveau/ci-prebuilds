#!/usr/bin/env node
/*
 * Prices a USE_SYSTEM_LIBS trim BEFORE the 25-30h rebuild that tests it.
 *
 * closure-reloc-audit.sh reports the closure as two totals: 65 DSOs and 13,373
 * symbol relocations on our chromium against 51 and 6,739 on Playwright's, and
 * the launch profile attributes 71% of the per-launch CPU delta to the musl
 * loader on the strength of them. What neither says is WHICH objects carry the
 * references, and that is the whole question for the trim, because musl's
 * `find_sym` walks the loaded-object list once per undefined reference: the
 * cost is roughly (references) x (objects searched), and unbundling a library
 * moves both factors only if the library actually leaves the closure.
 *
 * It usually does not. Dropping zlib from USE_SYSTEM_LIBS makes chromium carry
 * its own copy, but libz.so.1 stays loaded anyway as a dependency of the
 * fontconfig/freetype/harfbuzz stack we deliberately keep on the system. The
 * DSO count does not fall, only the references into it do. So this script
 * separates the libraries the trim can actually unload from the ones it cannot,
 * and reports the saving of each factor separately rather than one number that
 * silently mixes them.
 *
 *   node dso-symbol-census.cjs [binary]
 *
 * Prints a table on stderr and a JSON object on stdout.
 */

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

// The set the perf/chromium-unbundle-libs branch removes from USE_SYSTEM_LIBS,
// by SONAME prefix rather than by the gn name it is dropped under: one gn entry
// can be several shared objects (webp ships demux, mux and sharpyuv beside it)
// and only the shared objects are what the loader pays for.
const TRIMMED = [
  'libbrotlicommon', 'libbrotlidec', 'libbrotlienc',
  'libcrc32c',
  'libdav1d',
  'libdouble-conversion',
  'libhwy',
  'libjpeg',
  'libwebp', 'libsharpyuv',
  'libxml2',
  'libxslt', 'libexslt',
  'libopus',
  'libz.so',
  'libzstd',
];

function sh(cmd, args) {
  try {
    return execFileSync(cmd, args, { encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 });
  } catch {
    return '';
  }
}

function findBinary() {
  const explicit = process.argv[2];
  if (explicit) return explicit;
  const roots = fs.existsSync('/ms-playwright') ? fs.readdirSync('/ms-playwright') : [];
  for (const entry of roots.filter((e) => e.startsWith('chromium_headless_shell-'))) {
    const bin = path.join('/ms-playwright', entry,
      'chrome-headless-shell-linux64', 'chrome-headless-shell');
    if (fs.existsSync(bin)) return bin;
  }
  throw new Error('no chrome-headless-shell found; pass the binary as an argument');
}

function closure(bin) {
  const paths = new Set([bin]);
  for (const line of sh('ldd', [bin]).split('\n')) {
    const m = line.match(/=>\s+(\/\S+)/) || line.match(/^\s*(\/\S+)\s+\(0x/);
    if (m) paths.add(m[1]);
  }
  return [...paths];
}

function inspect(file) {
  const dynamic = sh('readelf', ['-d', '-W', file]);
  const needed = [...dynamic.matchAll(/NEEDED\s+Shared library: \[([^\]]+)\]/g)].map((m) => m[1]);
  const soname = (dynamic.match(/SONAME\s+Library soname: \[([^\]]+)\]/) || [])[1]
    || path.basename(file);

  const defined = new Set();
  const undef = new Set();
  for (const line of sh('readelf', ['--dyn-syms', '-W', file]).split('\n')) {
    const cols = line.trim().split(/\s+/);
    if (cols.length < 8 || !/^\d+:$/.test(cols[0])) continue;
    const name = cols[7].split('@')[0];
    if (!name) continue;
    if (cols[6] === 'UND') undef.add(name);
    else defined.add(name);
  }

  let symRelocs = 0;
  for (const line of sh('readelf', ['-r', '-W', file]).split('\n')) {
    if (/R_X86_64_(JUMP_SLOT|GLOB_DAT|64)\b/.test(line)) symRelocs += 1;
  }

  return { file, soname, needed, defined, undef, symRelocs };
}

const bin = findBinary();
const objects = closure(bin).map(inspect);
const byBinary = objects[0];

const isTrimmed = (soname) => TRIMMED.some((p) => soname.startsWith(p));
const trimmed = objects.filter((o) => o !== byBinary && isTrimmed(o.soname));

// A trimmed library leaves the closure only if nothing we KEEP still needs it.
// Anything reachable from a kept system library (the fontconfig/freetype/
// harfbuzz stack, mesa, the X libraries) is loaded regardless of what chromium
// itself bundles, so its DSO cost survives the trim untouched.
const keptNeeds = new Map();
for (const o of objects) {
  if (o === byBinary || isTrimmed(o.soname)) continue;
  for (const n of o.needed) {
    if (!keptNeeds.has(n)) keptNeeds.set(n, []);
    keptNeeds.get(n).push(o.soname);
  }
}

const rows = trimmed.map((o) => {
  const heldBy = keptNeeds.get(o.soname) || [];
  return {
    soname: o.soname,
    symbol_relocs: o.symRelocs,
    undefined_syms: o.undef.size,
    defined_syms: o.defined.size,
    unloads: heldBy.length === 0,
    held_by: heldBy,
  };
});

const unloading = rows.filter((r) => r.unloads).map((r) => r.soname);
const unloadingDefs = new Set();
for (const o of trimmed) {
  if (!unloading.includes(o.soname)) continue;
  for (const s of o.defined) unloadingDefs.add(s);
}

// References into the libraries that actually unload: they are the part of the
// remaining objects' undefined set that only those libraries define.
let refsFreed = 0;
for (const o of objects) {
  if (trimmed.includes(o)) continue;
  for (const s of o.undef) if (unloadingDefs.has(s)) refsFreed += 1;
}

const totals = {
  dsos: objects.length,
  symbol_relocs: objects.reduce((a, o) => a + o.symRelocs, 0),
  undefined_syms: objects.reduce((a, o) => a + o.undef.size, 0),
};
const freedRelocs = rows.filter((r) => r.unloads)
  .reduce((a, r) => a + r.symbol_relocs, 0);

const after = {
  dsos: totals.dsos - unloading.length,
  symbol_relocs: totals.symbol_relocs - freedRelocs,
  undefined_syms: totals.undefined_syms - refsFreed
    - rows.filter((r) => r.unloads).reduce((a, r) => a + r.undefined_syms, 0),
};

// musl resolves every reference against the loaded-object list, so the loader's
// work is bounded by references x objects. Neither factor alone is the saving
// and the product is an upper bound, not a prediction — report all three.
const report = {
  binary: bin,
  before: totals,
  after,
  trimmed_libraries: rows,
  unloads: unloading,
  held_in_closure: rows.filter((r) => !r.unloads).map((r) => r.soname),
  work_bound_ratio: Number(
    ((after.undefined_syms * after.dsos) / (totals.undefined_syms * totals.dsos)).toFixed(4)),
};

const pad = (s, n) => String(s).padEnd(n);
process.stderr.write(`census-binary ${bin}\n`);
process.stderr.write(`${pad('library', 26)}${pad('symrelocs', 11)}${pad('und', 7)}${pad('def', 7)}verdict\n`);
for (const r of rows) {
  const verdict = r.unloads ? 'unloads' : `stays (needed by ${r.held_by.join(', ')})`;
  process.stderr.write(
    `${pad(r.soname, 26)}${pad(r.symbol_relocs, 11)}${pad(r.undefined_syms, 7)}${pad(r.defined_syms, 7)}${verdict}\n`);
}
process.stderr.write(
  `\ndsos ${totals.dsos} -> ${after.dsos}   ` +
  `symbol-relocs ${totals.symbol_relocs} -> ${after.symbol_relocs}   ` +
  `undefined-refs ${totals.undefined_syms} -> ${after.undefined_syms}\n`);
process.stderr.write(`loader work bound ${report.work_bound_ratio}x of today\n`);

console.log(JSON.stringify(report, null, 2));
