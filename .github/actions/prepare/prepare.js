// Main half of the prepare action: the DOCKER_MODE / HOST_ADDRESS defaults the composite
// version set, plus a snapshot of where each prebuilt tool resolves right now, which the
// post half (assert-tools.js) compares against at the end of the job.
//
// JavaScript rather than composite because only a JS action can declare `post:`, and a
// post step with `post-if: always()` is the one placement that still prints on a job a
// later step turned red (actions/runner#1478).
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { spawnSync } = require('node:child_process')

const ASSERT_SCRIPT = '/usr/local/bin/assert-prebuilt-tools-in-use'

function exportVariable(name, value) {
  process.env[name] = value
  const envFile = process.env.GITHUB_ENV
  // Unset when the action is run by hand outside a runner; the in-process export above is
  // then all there is, and saying so beats appending to nothing.
  if (!envFile) {
    console.log(`${name}=${value} (no GITHUB_ENV: later steps will not see it)`)
    return
  }
  fs.appendFileSync(envFile, `${name}=${value}\n`)
  console.log(`${name}=${value}`)
}

function saveState(name, value) {
  const stateFile = process.env.GITHUB_STATE
  if (!stateFile) {
    return
  }
  fs.appendFileSync(stateFile, `${name}=${value}\n`)
}

// Image-side env vars take precedence — this action only fills the gap for the no-image
// case, where the job runs on the host VM.
const dockerMode = process.env.DOCKER_MODE || 'vm'
exportVariable('DOCKER_MODE', dockerMode)

if (dockerMode === 'dind') {
  // stdio inherited so the daemon's own boot log lands in this step, and a non-zero exit
  // fails it: a job that goes on without a docker daemon fails later and further away.
  const booted = spawnSync('start-dockerd', [], { stdio: 'inherit' })
  if (booted.error) {
    console.log(`::error::DOCKER_MODE=dind but start-dockerd could not run: ${JSON.stringify(booted.error.message)}`)
    process.exit(1)
  }
  if (booted.status !== 0) {
    console.log(`::error::start-dockerd exited ${JSON.stringify(booted.status)}`)
    process.exit(1)
  }
}

// 127.0.0.1 not localhost — forcing ipv4 avoids connection refused errors
exportVariable('HOST_ADDRESS', process.env.HOST_ADDRESS || '127.0.0.1')

// Absent on a plain VM job and on every image below the node layer. This action is a
// universal pre-flight, so "no prebuilt tools to account for" is not a finding.
if (fs.existsSync(ASSERT_SCRIPT)) {
  const snapshotPath = path.join(
    process.env.RUNNER_TEMP || os.tmpdir(),
    'ci-prebuilds-tools-at-prepare.tsv',
  )
  const snapshot = spawnSync(ASSERT_SCRIPT, ['--write-snapshot', snapshotPath], { stdio: 'inherit' })
  if (snapshot.status === 0) {
    saveState('tools_snapshot', snapshotPath)
  } else {
    // Only costs the post step the "at prepare" half of its wording, so it stays a notice:
    // the assertion still runs against the manifest the image baked.
    console.log(`::notice::could not snapshot the prebuilt tools (${JSON.stringify(snapshot.status)}); the post step will report against the image manifest alone`)
  }
}
