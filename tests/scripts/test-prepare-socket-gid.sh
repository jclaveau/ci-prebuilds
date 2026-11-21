#!/usr/bin/env bash
# Unit test for the socket-group join in .github/actions/prepare/prepare.js: the half that
# keeps a container job able to reach /var/run/docker.sock when the host hands it a gid no
# image baked (gid 111, 2026-11-21, Planner #850).
#
# prepare.js reads CI_PREBUILDS_DOCKER_SOCKET instead of /var/run/docker.sock here, and
# `sudo` and `getent` are shell scripts on a scratch PATH that record their argv, so nothing
# touches a real socket, a real group or a real sudoers rule. No network, no docker.
#
# The "job is not in the socket's group" rows need a file whose gid the test user is not a
# member of. As root the test chgrps its own fake socket; otherwise it borrows the gid of a
# system file nobody but root owns (gid 0 for a normal user), which every box has.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREPARE="$HERE/../../.github/actions/prepare/prepare.js"
[[ -f "$PREPARE" ]] || { echo "FAIL: $PREPARE not found" >&2; exit 1; }
command -v node >/dev/null || { echo "FAIL: node is needed to run the action under test" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
export PATH="$WORK/bin:$PATH"
export GITHUB_ENV="$WORK/github-env"
export GITHUB_STATE="$WORK/github-state"
: > "$GITHUB_ENV"
: > "$GITHUB_STATE"

# Both shims append their argv, so an assertion reads the calls in the order they were made.
# SUDO_RC and GETENT_GROUP are read at call time: each row sets them before running the action.
cat > "$WORK/bin/sudo" <<'SHIM'
#!/bin/sh
echo "sudo $*" >> "$CALLS"
if [ "${SUDO_RC:-0}" != "0" ]; then
  echo "sudo: a password is required" >&2
fi
exit "${SUDO_RC:-0}"
SHIM
cat > "$WORK/bin/getent" <<'SHIM'
#!/bin/sh
echo "getent $*" >> "$CALLS"
[ -n "${GETENT_GROUP:-}" ] || exit 2
echo "$GETENT_GROUP"
SHIM
chmod 755 "$WORK/bin/sudo" "$WORK/bin/getent"
export CALLS="$WORK/calls"

# A gid the test user is NOT a member of, and a fake socket carrying it.
FOREIGN_SOCKET="$WORK/foreign.sock"
: > "$FOREIGN_SOCKET"
if [[ "$(id -u)" == "0" ]]; then
  FOREIGN_GID=65123
  chgrp "$FOREIGN_GID" "$FOREIGN_SOCKET"
else
  FOREIGN_GID=0
  cp -p /etc/hosts "$FOREIGN_SOCKET" 2>/dev/null || true
  FOREIGN_SOCKET=/etc/hosts
  FOREIGN_GID=$(stat -c %g /etc/hosts)
fi
for member_gid in $(id -G); do
  [[ "$member_gid" == "$FOREIGN_GID" ]] && {
    echo "FAIL: gid $FOREIGN_GID is one of this user's own groups, so no row can prove a join" >&2
    exit 1
  }
done

# A gid the user IS a member of: its own, which no join should ever touch.
OWN_SOCKET="$WORK/own.sock"
: > "$OWN_SOCKET"

run_prepare() { # <socket path>
  : > "$CALLS"
  CI_PREBUILDS_DOCKER_SOCKET="$1" node "$PREPARE" 2>&1
}

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== a gid no group holds: groupadd then usermod, and the join is announced ==="
unset GETENT_GROUP
export SUDO_RC=0
out=$(run_prepare "$FOREIGN_SOCKET")
grep -qx "sudo -n groupadd -o -g $FOREIGN_GID docker-host-$FOREIGN_GID" "$CALLS" \
  || fail "no groupadd for gid $FOREIGN_GID; calls were: $(cat "$CALLS")"
grep -qx "sudo -n usermod -aG docker-host-$FOREIGN_GID $(id -un)" "$CALLS" \
  || fail "no usermod into docker-host-$FOREIGN_GID; calls were: $(cat "$CALLS")"
echo "$out" | grep -q "::notice::joined docker-host-$FOREIGN_GID (gid $FOREIGN_GID) so this job can reach $FOREIGN_SOCKET" \
  || fail "the join was not announced; output was: $out"

echo "=== a gid an existing group already holds: that group is joined, nothing is created ==="
export GETENT_GROUP="hostdocker:x:$FOREIGN_GID:"
out=$(run_prepare "$FOREIGN_SOCKET")
grep -q groupadd "$CALLS" && fail "groupadd ran although gid $FOREIGN_GID already had a group"
grep -qx "sudo -n usermod -aG hostdocker $(id -un)" "$CALLS" \
  || fail "the existing group was not joined; calls were: $(cat "$CALLS")"

echo "=== a gid the job already carries: no sudo at all ==="
unset GETENT_GROUP
out=$(run_prepare "$OWN_SOCKET")
[[ -s "$CALLS" ]] && fail "a gid the user already has triggered: $(cat "$CALLS")"
echo "$out" | grep -q '::notice::joined' && fail "a no-op announced a join: $out"

echo "=== no socket (a vm job, or dind before start-dockerd): no sudo at all ==="
out=$(run_prepare "$WORK/there-is-no-socket-here.sock")
[[ -s "$CALLS" ]] && fail "a missing socket triggered: $(cat "$CALLS")"

echo "=== sudo refused (an image without the dood sudoers drop-in): warning, job stays green ==="
export SUDO_RC=1
rc=0
out=$(run_prepare "$FOREIGN_SOCKET") || rc=$?
[[ "$rc" == "0" ]] || fail "a refused sudo failed the step (rc=$rc): $out"
echo "$out" | grep -q "::warning::$FOREIGN_SOCKET has gid $FOREIGN_GID" \
  || fail "no warning naming the socket and its gid; output was: $out"
echo "$out" | grep -q 'sudo: a password is required' \
  || fail "the warning dropped sudo's own reason; output was: $out"

echo
echo "PASS: all 5 rows"
