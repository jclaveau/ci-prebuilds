---
name: reference_bash_set_u_empty_assoc_array_unbound
description: under `set -u` (bash 5.2.37), `${#arr[@]}`/`${!arr[@]}` on a `declare -A`'d array with zero assigned elements is UNBOUND, not empty — killed 7/8 tests in scripts/check-runtime-parity.sh's rewrite
metadata:
  type: project
---

`declare -A alpine_passed` with no element ever assigned makes
`${#alpine_passed[@]}` (and `${!alpine_passed[@]}`) throw "variable sans
liaison" (unbound variable) under `set -u`, not read as 0/empty. This is a
bash 5.2.37 gate-script gotcha distinct from the zsh-interactive-shell
associative-array issue in [[feedback_zsh_bash_tool_quirks]] (zsh has no
associative arrays at all; this is bash proper failing only when the array
stayed empty).

**Fix pattern:** don't probe the array's own size/keys to test "did this
browser/suite run." Track presence from the read loop that populates it —
accumulate a separate newline-joined string of keys seen (or use the
`${arr[$k]+set}` membership test per key), and test that string/membership
instead of `${#arr[@]}`. Used in `scripts/check-runtime-parity.sh` (PR #315,
commit `3b5f769`): `alpine_suites+="$suite"$'\n'` inside the `while read`
loop, then `[ -n "$alpine_suites" ]` in place of `${#alpine_passed[@]}`.

**How to apply:** any new `scripts/*.sh` gate written under `set -u` (all of
them are) that uses a `declare -A` array to detect "was anything read into
this" must use the membership/accumulator pattern above, never
`${#arr[@]}` — the empty case is exactly the one this repo's parity gates
need to detect correctly (a browser or suite absent from one side).
