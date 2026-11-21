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
