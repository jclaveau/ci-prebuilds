export const meta = {
  name: 'conformance-gap-triage',
  description: 'Autonomous per-browser attack: root-cause EVERY remaining Alpine-only conformance skip and emit a concrete, ordered fix queue (attempt even structural). Never asks — produces executable actions.',
  whenToUse: 'To attack the remaining conformance parity gap. Runs one agent per browser in parallel, each returning an ordered attack queue the caller executes in a loop.',
  phases: [
    { title: 'Attack' },
    { title: 'Sequence' }
  ]
}

// Autonomous: no ask/wait. Each browser agent enumerates its CURRENT remaining
// skips and emits concrete fix actions for ALL of them, ranked by feasibility,
// attempting a real source patch even for "structural" ones. Override the
// browser set with args:{browsers:[...]}.
const BROWSERS = (args && args.browsers) || [
  { key: 'chromium-fs', filesTxt: 'chromium.files.txt', titlesTxt: 'chromium.titles.txt', artifact: 'chs-fs-edge', rev: '1223', producerFlag: 'build_chromium_headless_shell_from_source' },
  { key: 'firefox',     filesTxt: 'firefox.files.txt',   titlesTxt: 'firefox.titles.txt',   artifact: 'edge',        rev: '1522', producerFlag: 'build_firefox' },
  { key: 'webkit',      filesTxt: 'webkit.files.txt',    titlesTxt: 'webkit.titles.txt',    artifact: 'wk-edge',     rev: '2287', producerFlag: 'build_webkit' },
]

const ACTION_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['browser', 'actions', 'summary'],
  properties: {
    browser: { type: 'string' },
    summary: { type: 'string' },
    actions: {
      type: 'array',
      description: 'EVERY remaining attackable cluster as a concrete, ordered action. Cheapest/highest-confidence first. Attempt even structural (emit the best source patch).',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['rank', 'cluster', 'feasibility', 'type', 'root_cause', 'concrete_change', 'target_tests', 'needs_local_probe', 'needs_rebuild'],
        properties: {
          rank: { type: 'number' },
          cluster: { type: 'string' },
          feasibility: { type: 'string', enum: ['pass-now', 'config-fix', 'source-patch', 'structural-attempt'], description: 'structural-attempt = no clean fix known, but emit the most plausible source patch to TRY anyway' },
          type: { type: 'string', enum: ['skiplist-remove', 'runner-config', 'source-patch'] },
          root_cause: { type: 'string' },
          concrete_change: { type: 'string', description: 'EXACT executable change: the skip-list lines/regex to delete, OR the apk/env runner diff, OR the source file + patch hunk + cmake/build flag. Precise enough to apply verbatim.' },
          target_tests: { type: 'number' },
          needs_local_probe: { type: 'boolean' },
          needs_rebuild: { type: 'boolean' }
        }
      }
    }
  }
}

const SEQ_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['queue', 'total_target_tests'],
  properties: {
    queue: {
      type: 'array',
      description: 'Global execution order across browsers: all no-rebuild actions first (batched per browser), then one batched rebuild per browser folding all its source-patch/structural-attempt actions.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['step', 'browser', 'kind', 'clusters', 'target_tests', 'needs_rebuild'],
        properties: {
          step: { type: 'number' },
          browser: { type: 'string' },
          kind: { type: 'string', enum: ['skiplist-remove', 'runner-config', 'batched-rebuild'] },
          clusters: { type: 'array', items: { type: 'string' } },
          target_tests: { type: 'number' },
          needs_rebuild: { type: 'boolean' }
        }
      }
    },
    total_target_tests: { type: 'number' }
  }
}

phase('Attack')

const results = await parallel(
  BROWSERS.map(b => () => agent(
    `Autonomously attack EVERY remaining Alpine-only PW-conformance skip for ${b.key}. Do NOT ask questions or defer — emit a concrete, ordered, executable fix queue for ALL remaining clusters, attempting a real source patch even for structural ones.

Repo: /home/jean/dev/ci-prebuilds. Branch: feat/webkit-alpine-branch-c.
Skip-list: playwright/alpine-browsers/conformance/skip-list/${b.filesTxt} + ${b.titlesTxt}.
Ubuntu baseline (out-of-scope if shared): skip-list-ubuntu/. Local PW source: tmp/pw-cc-repro/pw-src.
Published artifact: ghcr.io/jclaveau/playwright-alpine-browsers:${b.artifact} (rev ${b.rev}). Producer rebuild flag: ${b.producerFlag}.

Method:
1. Read the current ${b.filesTxt}/${b.titlesTxt}; list every ACTIVE skip (non-comment). Exclude entries also in skip-list-ubuntu (PW-known, out-of-scope) and pure PW-tooling (cli-codegen/trace-viewer/slowmo).
2. For each remaining cluster, read the test source in tmp/pw-cc-repro/pw-src and (for native failures) the browser source at the pinned SHA via web. Root-cause precisely.
3. Emit a concrete action for EVERY cluster — none deferred:
   - pass-now  → the exact skip-list lines/regex to delete (type=skiplist-remove).
   - config-fix → the exact apk pkg / env var runner change in conformance/build-runner.sh (type=runner-config), plus the skip-list lines to delete.
   - source-patch → the exact source file + patch hunk + any cmake/GN/build flag, in prep-source.sh idiom (type=source-patch, needs_rebuild=true).
   - structural-attempt → NO clean fix known, but still emit the MOST PLAUSIBLE source patch or build flag to try (e.g. WebKit ENABLE_VIDEO / GStreamer plugin build, WPE encodeFrame !PLATFORM guard, FF Juggler docShell/Fission patch). Mark feasibility=structural-attempt, needs_rebuild=true. NEVER skip a cluster as unfixable — always propose an attempt.
4. Rank cheapest+highest-confidence first (pass-now, config-fix, source-patch, structural-attempt). Set needs_local_probe=true where a docker probe against the published artifact would confirm before committing.

Return the full action list per schema. concrete_change must be precise enough to apply verbatim.`,
    { label: 'attack:' + b.key, phase: 'Attack', schema: ACTION_SCHEMA, agentType: 'general-purpose' }
  ))
)

const findings = results.filter(Boolean)

phase('Sequence')

const sequence = await agent(
  `Build a single global execution queue from these per-browser attack lists. No asking — output the order to execute.

${JSON.stringify(findings, null, 2)}

Rules:
- All no-rebuild actions FIRST (skiplist-remove, runner-config), batched per browser — these validate via cheap conformance-only dispatch.
- Then exactly ONE batched-rebuild step per browser that folds ALL its source-patch + structural-attempt actions into a single producer rebuild (amortize the multi-hour cost) — the 3 browsers' rebuilds run in parallel (separate CI concurrency channels).
- target_tests per step = sum of its clusters' target_tests. total_target_tests = grand sum.`,
  { label: 'sequence', phase: 'Sequence', schema: SEQ_SCHEMA, agentType: 'general-purpose' }
)

return { findings, sequence }
