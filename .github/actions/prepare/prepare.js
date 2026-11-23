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
// The path is a constant in production; the override exists so
// tests/scripts/test-prepare-socket-gid.sh can point it at a socket whose gid it owns.
const DOCKER_SOCKET = process.env.CI_PREBUILDS_DOCKER_SOCKET || '/var/run/docker.sock'

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

// A container job is handed the HOST's /var/run/docker.sock, which keeps the host's gid,
// and the images can only bake a group per gid GitHub has shipped so far
// (DOCKER_HOST_GROUP_IDS in docker/Dockerfile): gid 111 turned up on 2026-11-21 and locked
// uid 1001 out of every docker call in the job. The image's own ENTRYPOINT cannot align
// them — the runner replaces it with `tail -f /dev/null` — but this step can, because
// `docker exec` resolves the user's supplementary groups from /etc/group at every exec, so
// the group joined here reaches every later step. Needs the narrow `groupadd`/`usermod`
// sudoers entry dood/Dockerfile installs; without it the job gets a warning naming the gid
// instead of a wall of "permission denied" from whichever step touches docker first.
function joinDockerSocketGroup() {
  let socketGid
  try {
    socketGid = fs.statSync(DOCKER_SOCKET).gid
  } catch {
    // No socket at all: a plain VM job, or a dind image before start-dockerd.
    return
  }
  if (process.getgid() === socketGid || process.getgroups().includes(socketGid)) {
    return
  }
  // A group may already hold that gid under a name of its own (`docker` itself on an image
  // built with DOCKER_GROUP_ID equal to it), in which case joining it is the whole job.
  const resolved = spawnSync('getent', ['group', String(socketGid)], { encoding: 'utf8' })
  const groupName = resolved.status === 0
    ? resolved.stdout.trim().split(':')[0]
    : `docker-host-${socketGid}`
  const user = os.userInfo().username
  if (resolved.status !== 0) {
    const created = spawnSync('sudo', ['-n', 'groupadd', '-o', '-g', String(socketGid), groupName], { encoding: 'utf8' })
    if (created.status !== 0) {
      console.log(`::warning::${DOCKER_SOCKET} has gid ${socketGid}, which this image bakes no group for, and \`sudo -n groupadd\` failed (${JSON.stringify((created.stderr || '').trim() || created.status)}): every docker call in this job will read "permission denied"`)
      return
    }
  }
  const joined = spawnSync('sudo', ['-n', 'usermod', '-aG', groupName, user], { encoding: 'utf8' })
  if (joined.status !== 0) {
    console.log(`::warning::${DOCKER_SOCKET} has gid ${socketGid} and \`sudo -n usermod -aG ${groupName} ${user}\` failed (${JSON.stringify((joined.stderr || '').trim() || joined.status)}): every docker call in this job will read "permission denied"`)
    return
  }
  console.log(`::notice::joined ${groupName} (gid ${socketGid}) so this job can reach ${DOCKER_SOCKET}`)
}

joinDockerSocketGroup()

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
  const snapshotDir = process.env.RUNNER_TEMP || os.tmpdir()
  // RUNNER_TEMP is a promise the runner keeps and act does not: its .actrc value often
  // names a directory nothing creates, and the write below would fail on a job that is
  // otherwise fine.
  fs.mkdirSync(snapshotDir, { recursive: true })
  const snapshotPath = path.join(snapshotDir, 'ci-prebuilds-tools-at-prepare.tsv')
  const snapshot = spawnSync(ASSERT_SCRIPT, ['--write-snapshot', snapshotPath], { stdio: 'inherit' })
  if (snapshot.status === 0) {
    saveState('tools_snapshot', snapshotPath)
  } else {
    // Only costs the post step the "at prepare" half of its wording, so it stays a notice:
    // the assertion still runs against the manifest the image baked.
    console.log(`::notice::could not snapshot the prebuilt tools (${JSON.stringify(snapshot.status)}); the post step will report against the image manifest alone`)
  }
}

// The three opt-in checks below read the checkout, which is why the README puts this action
// right after actions/checkout. Each is off unless asked for: this action runs in every
// job, and a job with no pnpm or no .nvmrc is not a finding.
function readBooleanInput(name) {
  const value = (process.env[`INPUT_${name.toUpperCase()}`] || 'false').trim()
  if (value !== 'true' && value !== 'false') {
    console.log(`::error::${name} is true or false, got ${JSON.stringify(value)}`)
    process.exit(1)
  }
  return value === 'true'
}

function workspaceFile(relativePath) {
  return path.resolve(process.env.GITHUB_WORKSPACE || process.cwd(), relativePath)
}

// The version a command prints, or null when it is not on PATH or fails.
function commandVersion(command) {
  const ran = spawnSync(command, ['--version'], { encoding: 'utf8' })
  if (ran.error || ran.status !== 0) {
    return null
  }
  return ran.stdout.trim().replace(/^v/, '')
}

if (readBooleanInput('pnpm-store')) {
  // A file of its own, not inline, so tests/scripts/test-pnpm-store.sh runs every row of
  // it without a runner.
  const storeScript = path.join(__dirname, 'pnpm-store.sh')
  const resolved = spawnSync('bash', [storeScript], { stdio: 'inherit' })
  if (resolved.error || resolved.status !== 0) {
    console.log(`::error::the pnpm store could not be resolved (${JSON.stringify(resolved.error ? resolved.error.message : resolved.status)})`)
    process.exit(1)
  }
}

const nodeVersionFile = (process.env['INPUT_NODE-VERSION-FILE'] || '').trim()
if (nodeVersionFile && dockerMode === 'vm') {
  console.log(`DOCKER_MODE=vm: no image node to compare with ${nodeVersionFile}, setup-node reads it`)
} else if (nodeVersionFile) {
  let pinned
  try {
    pinned = fs.readFileSync(workspaceFile(nodeVersionFile), 'utf8').trim().replace(/^v/, '')
  } catch (error) {
    console.log(`::error::node-version-file ${JSON.stringify(nodeVersionFile)} could not be read (${JSON.stringify(error.code || error.message)}): run prepare after actions/checkout`)
    process.exit(1)
  }
  // An alias (lts/*, node) names no version the image could be held to.
  if (!/^\d+(\.\d+){0,2}$/.test(pinned)) {
    console.log(`::error::${nodeVersionFile} pins ${JSON.stringify(pinned)}: only a numeric version can be compared with the image node`)
    process.exit(1)
  }
  const imageNode = commandVersion('node')
  if (imageNode === null) {
    console.log(`::error::${nodeVersionFile} pins node ${pinned}, and no node runs on PATH`)
    process.exit(1)
  }
  // major.minor at most: a patch bump ships with the next image tag, and is no reason to
  // fail every job until then.
  const precision = Math.min(pinned.split('.').length, 2)
  const expected = pinned.split('.').slice(0, precision).join('.')
  const actual = imageNode.split('.').slice(0, precision).join('.')
  if (expected !== actual) {
    console.log(`::error::node mismatch: ${nodeVersionFile}=${expected} image=${actual} — bump the image tag`)
    process.exit(1)
  }
  console.log(`node ${imageNode} matches ${nodeVersionFile} ${expected}`)
}

if (readBooleanInput('compare-pnpm-pin')) {
  let packageManager
  try {
    packageManager = JSON.parse(fs.readFileSync(workspaceFile('package.json'), 'utf8')).packageManager
  } catch (error) {
    console.log(`::error::package.json could not be read (${JSON.stringify(error.code || error.message)}): run prepare after actions/checkout`)
    process.exit(1)
  }
  // corepack appends the tarball's hash (`pnpm@10.0.0+sha512.…`); the version is before it.
  const pin = /^pnpm@([^+]+)/.exec(packageManager || '')
  if (!pin) {
    console.log(`::error::package.json declares no pnpm packageManager pin (packageManager=${JSON.stringify(packageManager)})`)
    process.exit(1)
  }
  const installed = commandVersion('pnpm')
  const matches = installed === pin[1]
  const outputFile = process.env.GITHUB_OUTPUT
  if (outputFile) {
    fs.appendFileSync(outputFile, `pnpm-matches-pin=${matches}\n`)
  }
  console.log(`packageManager pins pnpm ${pin[1]}, image ships ${installed || 'none'} (pnpm-matches-pin=${matches})`)
}
