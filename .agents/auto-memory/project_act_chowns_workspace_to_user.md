---
name: project-act-chowns-workspace-to-user
description: `act` runs `docker exec chown -R <uid>:<gid> workspace` matching its `--user` target — so host-side cleanup as a different UID needs sudo
metadata:
  type: project
---

`act` (nektos) reconciles workspace ownership with the `--user` override by
running `docker exec chown -R <uid>:<gid> <workspace>` during container setup.
After the job, the bind-mounted host directory is owned by the target UID,
not by whoever launched `act`.

**Why this matters:** under `act --bind --user 1000:1000` running on a GHA host
(GHA runner = UID 1001 per [[project-gha-runner-uid-is-1001]]), `act` chowns the
workspace to 1000:1000. The post-job host shell, still UID 1001, then can't
unlink files inside that dir → `rm: cannot remove '…': Permission denied`. The
TP `Bind-mode host-UID recipe` step hit this exactly once (commit `2d234c3`).

**How to apply:** TP cleanup of `act --bind` test directories must use `sudo
rm -rf "$TESTDIR"` whenever the act target UID differs from the runner UID. The
existing two TP steps both do this — keep the pattern.

Side note: this is also why a `mktemp -d` outside `$GITHUB_WORKSPACE` fails
differently — see [[project-tp-bind-test-pattern]].
