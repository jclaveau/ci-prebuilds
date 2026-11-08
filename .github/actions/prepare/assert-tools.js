// Post half of the prepare action: name every tool the image prebuilt that the job stopped
// running, so a step that re-downloads node or pnpm is visible instead of silently costing
// the time the image was taken for.
//
// The comparison itself lives in the image (/usr/local/bin/assert-prebuilt-tools-in-use), so
// there is one implementation of it, shared with a hand-run `docker run` check. This file
// only decides when to call it and what its exit code means for the job.
'use strict'

const fs = require('node:fs')
const { spawnSync } = require('node:child_process')

const ASSERT_SCRIPT = '/usr/local/bin/assert-prebuilt-tools-in-use'

const severity = (process.env['INPUT_TOOLS-SEVERITY'] || 'warning').trim()
if (severity !== 'warning' && severity !== 'error') {
  // A typo in the input is a workflow bug, not a finding: loud in both modes, because
  // neither mode is what the consumer asked for.
  console.log(`::error::tools-severity is warning or error, got ${JSON.stringify(severity)}`)
  process.exit(1)
}

if (!fs.existsSync(ASSERT_SCRIPT)) {
  console.log('no prebuilt-tool manifest: not a ci-prebuilds image at or above the node layer')
  process.exit(0)
}

const args = ['--severity', severity]
const snapshotPath = process.env.STATE_tools_snapshot
// Only present when the main step managed to write it; without it the report loses the
// "was still the image's at prepare" half of its wording, not the finding.
if (snapshotPath && fs.existsSync(snapshotPath)) {
  args.push('--snapshot', snapshotPath)
}

const checked = spawnSync(ASSERT_SCRIPT, args, { stdio: 'inherit' })
if (checked.error) {
  console.log(`::${severity}::could not run ${ASSERT_SCRIPT}: ${JSON.stringify(checked.error.message)}`)
  process.exit(severity === 'error' ? 1 : 0)
}

// The script exits 1 on a finding in error mode, and on a broken manifest or a bad flag in
// both — it is a gate when called by hand. Here it is a pre-flight every consumer of these
// images runs, so warning mode never fails the job: a tag bump must not turn a green
// workflow red. Its annotations already carry the right level.
if (checked.status !== 0 && severity === 'warning') {
  process.exit(0)
}
process.exit(checked.status === null ? 1 : checked.status)
