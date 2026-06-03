# PARKED (2026-05-29): host-UID option for dood + `act --bind`

## Problem
The images set `runner` to **UID 1001** (and `packer` to 1000) in `base/Dockerfile` to mirror GitHub's
`ubuntu-latest`. Under `act --bind` (workdir bind-mounted, not copied), step processes run as the image
USER (1001), so files created in the workspace land on the **host owned by 1001** — friction for a local
dev whose UID is 1000.

Idea floated: add an **option (dood mode) to run as the host user id** so bind-mounted files are owned by
the host user.

## Hard constraint
Default UID must stay **1001** — it's deliberately matching GitHub's runner so the images are a faithful
`ubuntu-latest` drop-in. Any host-UID behaviour must be **opt-in**, not the default.

## Must verify before designing (don't guess act internals)
- Which user does `act` run step processes as? (Observed by user: 1001 → act respects the image USER.)
- Does `act` actually run the image **ENTRYPOINT** at container start? Evidence it's unreliable: the dind
  act smoke test (`tests/act/smoke-dind.yml`) calls `start-dockerd` as an explicit **step**, not via the
  entrypoint. If the entrypoint doesn't run under act, a fixuid-style entrypoint remap won't work and the
  reliable lever is `act --container-options --user`.
- Under an arbitrary `--user <uid>:<gid>`: does **sudo** still work (sudoers entries are by *name*
  runner/packer, not uid)? Is **$HOME** writable (/home/runner is owned by 1001)? Missing `/etc/passwd`
  entry side effects?

## Candidate approaches (pick after the spike)
1. **Spike first (recommended):** locally `act --bind --container-options '--user $(id -u):$(id -g)'`
   against `ubuntu-dood`; observe ownership + whether sudo/$HOME break; design the minimal change from facts.
2. **Runtime `--user` + image tweaks:** make the image tolerate an arbitrary UID (writable $HOME via HOME
   override; sudo not relied upon or opened). Document the act invocation. No entrypoint magic.
3. **fixuid-style entrypoint remap, env-gated:** `RUNNER_UID`/`RUNNER_GID` → `usermod`/`groupmod` +
   `chown /home/runner` then exec as runner; default unchanged (1001). Depends on the entrypoint running.

## Scope leaning
**dood only** — running **dind** as an arbitrary non-sudo UID would break `start-dockerd` (needs sudo) and
the inner daemon. (Related: [[FUSE_OVERLAYFS_OPTIMIZATION]], [[TRUEDIND_MIGRATION]].)

## Where we left off
In plan mode I asked (approach? scope?), user chose to park before answering. No code written for this.
Resume by running approach 1 (the spike), then re-plan.
