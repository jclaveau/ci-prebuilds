export const meta = {
  name: 'conformance-gap-triage',
  description: 'Root-cause + ROI-rank the remaining PW-conformance skip clusters (Alpine-vs-Ubuntu delta) per browser',
  whenToUse: 'After a conformance iter lands, to decide which skip clusters are worth attacking next. Pass args to override the cluster list; omit for the full default sweep.',
  phases: [
    { title: 'Investigate' },
    { title: 'Synthesize' }
  ]
}

// Default cluster catalog. Override by passing `args: { clusters: [...] }` with
// the same shape, or `args: { only: ['trace-viewer', ...] }` to run a subset.
const DEFAULT_CLUSTERS = [
  {
    key: 'trace-viewer',
    scope: 'FF+WK+CHS-fs',
    files: 'tests/library/trace-viewer.spec.ts + tests/library/trace-viewer-scrub.spec.ts',
    hypothesis: 'Recorder-UI internal chromium version mismatch (Alpine :3.22 chromium 142 vs PW-pinned 148). Bundling a closer chromium may recover; else structural.',
    est_tests: 360,
  },
  {
    key: 'cli-codegen-lang',
    scope: 'FF+WK+CHS-fs',
    files: 'tests/library/inspector/cli-codegen-{python,python-async,pytest,test,javascript,csharp,java}.spec.ts',
    hypothesis: 'Codegen CLI subprocess writes zero bytes (harness/subprocess launch), NOT divergent output strings. Un-skip probe needed post multi-stage chromium bundle.',
    est_tests: 216,
  },
  {
    key: 'ff-title-longtail',
    scope: 'FF',
    file_to_review: 'playwright/alpine-browsers/conformance/skip-list/firefox.titles.txt',
    hypothesis: 'Coarse bucket of ~128 titles = 5 orthogonal sub-clusters (juggler-frame, juggler-console/pageError, musl-icu-locale, cors/csp string-variance, tail) + dead-weight trace-viewer + upstream-dupes.',
    est_tests: 128,
  },
  {
    key: 'wk-title-longtail',
    scope: 'WK',
    file_to_review: 'playwright/alpine-browsers/conformance/skip-list/webkit.titles.txt',
    hypothesis: 'Locale (icu-data-full missing), video-codec (gst-plugins-ugly/openh264 missing), connect-headed (structural), locator-generator (upstream). Runner-image fixes recover most.',
    est_tests: 17,
  },
  {
    key: 'chs-fs-cookies-partitioned',
    scope: 'CHS-fs',
    hypothesis: 'CHIPS/Partitioned cookie skip is a defensive CHS-apk-era carryover. Chromium 148 from-source ships CHIPS on by default, no cookie feature suppression → likely full recovery. Un-skip probe.',
    est_tests: 15,
  },
  {
    key: 'chs-fs-drag-wheel-drop',
    scope: 'CHS-fs',
    files: 'tests/page/page-drag.spec.ts + tests/page/wheel.spec.ts + tests/page/page-drop.spec.ts',
    hypothesis: '//headless:headless_shell GN target strips DragController + wheel forwarding. Identical in from-source 148 → structural, NOT apk-vs-source.',
    est_tests: 24,
  },
  {
    key: 'chs-fs-screenshot',
    scope: 'CHS-fs',
    files: 'tests/library/screenshot.spec.ts + tests/page/{page,elementhandle}-screenshot.spec.ts + tests/page/page-aria-snapshot{,-ai}.spec.ts',
    hypothesis: 'Pixel-diff vs glibc/macOS reference PNGs (Alpine freetype/fontconfig rasterization). Pixel files structural; aria-snapshot may not rasterize → bisect.',
    est_tests: 60,
  }
]

const CLUSTER_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['cluster', 'root_cause', 'fix_candidates', 'best_roi', 'files_examined'],
  properties: {
    cluster: { type: 'string' },
    root_cause: { type: 'string' },
    fix_candidates: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['approach', 'effort_hours_est', 'expected_recovery_tests', 'risk_notes'],
        properties: {
          approach: { type: 'string' },
          effort_hours_est: { type: 'number' },
          expected_recovery_tests: { type: 'number' },
          risk_notes: { type: 'string' }
        }
      }
    },
    best_roi: { type: 'string' },
    files_examined: { type: 'array', items: { type: 'string' } }
  }
}

const SYNTH_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['top_actions', 'structural_close', 'quick_wins', 'total_potential_tests'],
  properties: {
    top_actions: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['rank', 'approach', 'effort_hours', 'tests_recovered', 'cluster'],
        properties: {
          rank: { type: 'number' },
          approach: { type: 'string' },
          effort_hours: { type: 'number' },
          tests_recovered: { type: 'number' },
          cluster: { type: 'string' }
        }
      }
    },
    structural_close: { type: 'array', items: { type: 'string' } },
    quick_wins: { type: 'array', items: { type: 'string' } },
    total_potential_tests: { type: 'number' }
  }
}

const catalog = (args && args.clusters) || DEFAULT_CLUSTERS
const clusters = (args && args.only)
  ? catalog.filter(c => args.only.includes(c.key))
  : catalog

phase('Investigate')

const results = await parallel(
  clusters.map(c => () => agent(
    `Investigate PW conformance skip cluster "${c.key}" on Alpine (${c.scope}).

Hypothesis: ${c.hypothesis}
Est test count in cluster: ${c.est_tests}
${c.files ? 'Spec files:\n' + c.files : ''}
${c.file_to_review ? 'Skip-list file to review: ' + c.file_to_review : ''}

Repo root: /home/jean/dev/ci-prebuilds. Branch: feat/webkit-alpine-branch-c.

Tasks:
1. Read auto-memory: .agents/auto-memory/project_pw_conformance_visibility_cluster.md and adjacent project_*.md that reference this cluster.
2. Read the relevant skip-list rationale under playwright/alpine-browsers/conformance/skip-list/.
3. If test-fail log fragments exist under /tmp/iter*, /tmp/wk*, /tmp/ff*, /tmp/iterchsfs*, read one sample of the cluster.
4. Optionally check git log via Bash: git log --all --oneline --grep="<cluster_keyword>" | head -20.
5. Identify concrete root cause + 2-4 fix candidates (source patch / runner-image change / skip-list improvement / accept-as-structural).
6. Estimate effort (hours) and expected test recovery per candidate. Note risks.

Return structured verdict per schema. best_roi = one sentence naming the top candidate.`,
    { label: 'audit:' + c.key, phase: 'Investigate', schema: CLUSTER_SCHEMA, agentType: 'general-purpose' }
  ))
)

const findings = results.filter(Boolean)

phase('Synthesize')

const synthesis = await agent(
  `Synthesize ${findings.length} cluster investigation results into a ROI-ranked action plan.

Cluster findings:
${JSON.stringify(findings, null, 2)}

Rank the top 5 highest-ROI attack paths across all clusters (approach + effort_hours + tests_recovered).
Identify clusters to close as structural (skip permanently, no realistic fix).
Identify quick-wins landable in the next commit (< 1h effort each).
Compute total_potential_tests = sum of expected_recovery across all viable fixes.`,
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTH_SCHEMA, agentType: 'general-purpose' }
)

return { findings, synthesis }
