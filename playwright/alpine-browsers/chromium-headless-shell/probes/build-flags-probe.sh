#!/bin/bash
# DIAG BRANCH ONLY — re-links headless_shell in a round image with a symbol
# ordering file built from the box's perf profile (issue #249 item 1: our hot
# Blink code sits in two bands of .text, official's in one). Dispatched via
# chromium-build-flags-probe.yml with script_ref=diag/chromium-symtab-dump.
# Produces /out/headless_shell_ord.gz (stripped) + lld's printed symbol orders.
set -uo pipefail
OUT="${1:?outdir}"
mkdir -p "$OUT"
WORK=/work
set -a; . "$WORK/versions.env"; . "$WORK/derived.env"; set +a
CHS_VER="${CHROMIUM_HEADLESS_SHELL_VERSION:?}"
cd "$WORK/chromium-src/chromium-$CHS_VER/out/headless" || exit 2
LLVM=$(ls -d /usr/lib/llvm2*/bin | sort | tail -1)
LINK=$(ninja -t commands headless_shell 2>/dev/null | tail -1)
[[ "$LINK" == *gcc_link_wrapper.py* ]] || { echo "ERROR: unexpected link line: ${LINK:0:200}" >&2; exit 2; }
echo "$LINK" > "$OUT/link-cmd.txt"

# ninja writes the response file only when it runs the edge; r12 never linked.
if [[ ! -f headless_shell.rsp ]]; then
  ninja -n -d keeprsp headless_shell >/dev/null 2>&1 || true
fi
if [[ ! -f headless_shell.rsp ]]; then
  grep -A6 '^rule link$' toolchain.ninja | tee "$OUT/rule-link.txt"
  python3 - <<'PY'
import re
src = open('obj/headless/headless_shell.ninja').read().replace('$\n', '')
m = re.search(r'^build (?:\./)?headless_shell: link (.*)$', src, re.M)
assert m, 'no link edge for headless_shell'
ins = re.split(r' \|\|? ', m.group(1))[0]
def unesc(s): return s.replace('$ ', ' ').replace('$:', ':').replace('$$', '$')
inputs = [unesc(t) for t in ins.split()]
tail = src[m.end():]
vars = dict(re.findall(r'^  (\w+) = (.*)$', tail.split('\nbuild ')[0], re.M))
parts = '\n'.join(inputs)
for k in ('solibs', 'libs', 'rlibs'):
    if vars.get(k): parts += ' ' + unesc(vars[k])
open('headless_shell.rsp', 'w').write(parts + '\n')
print('rsp: %d inputs, vars %s' % (len(inputs), {k: len(v) for k, v in vars.items()}))
PY
fi
[[ -f headless_shell.rsp ]] || { echo "ERROR: could not produce headless_shell.rsp" >&2; exit 2; }
wc -c headless_shell.rsp; head -c 300 headless_shell.rsp; echo; tail -c 400 headless_shell.rsp; echo
cp headless_shell.rsp "$OUT/headless_shell.rsp"

relink() {  # relink <suffix> <extra ldflags...>
  local sfx="$1"; shift
  local cmd="${LINK//\"\.\/headless_shell\"/\"./headless_shell_$sfx\"}"
  cmd="${cmd//--output=\"\.\/headless_shell_$sfx\"/--output=\"./headless_shell_$sfx\"}"
  cmd="$cmd $*"
  echo "### link $sfx: $(date -u +%H:%M:%S)"
  local t0=$SECONDS
  eval "$cmd" > "$OUT/link-$sfx.log" 2>&1; local rc=$?
  echo "### link $sfx rc=$rc in $((SECONDS-t0))s"; tail -5 "$OUT/link-$sfx.log"
  [[ $rc -eq 0 ]] || return $rc
  ls -la "headless_shell_$sfx"
  "$LLVM/llvm-nm" -n --defined-only -S "headless_shell_$sfx" | gzip -6 > "$OUT/symtab-$sfx.nm.gz"
  "$LLVM/llvm-readelf" -SW "headless_shell_$sfx" | grep -E "\] \.text" > "$OUT/text-$sfx.txt"
  gzip -6 -c "headless_shell_$sfx" > "$OUT/headless_shell_$sfx-unstripped.gz"
  ls -la "$OUT/headless_shell_$sfx-unstripped.gz"
}

relink ctl || exit 3
cp headless_shell_ctl headless_shell
echo "### census $(date -u +%H:%M:%S)"
VARIANT=headless bash /probes/link-census.sh "$WORK" "$OUT/census"
echo "### census done $(date -u +%H:%M:%S)"
echo "### DONE"
