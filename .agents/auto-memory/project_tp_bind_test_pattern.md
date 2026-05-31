---
name: project-tp-bind-test-pattern
description: TP bind-mode tests live under `$GITHUB_WORKSPACE/_bind-test*`, not `mktemp -d`, and clean up with `sudo rm -rf`
metadata:
  type: project
---

Pattern for any TP step exercising `act --bind`:

```yaml
- name: <descriptive name>
  if: matrix.mode == 'dood'
  run: |
    TESTDIR="$GITHUB_WORKSPACE/_bind-test<suffix>"
    rm -rf "$TESTDIR"
    mkdir -p "$TESTDIR"
    chmod g+rwx "$TESTDIR"
    pushd "$TESTDIR"
    act push -W "$GITHUB_WORKSPACE/tests/act/<smoke>.yml" --bind \
      -P ubuntu-latest="$IMG" \
      --container-options "<recipe per [[project-act-bind-host-uid-recipe]]>"
    # assertions on ownership / content
    popd
    sudo rm -rf "$TESTDIR"
```

**Why this exact shape:**

- `$GITHUB_WORKSPACE/_bind-test*` instead of `mktemp -d` — `/tmp` + act's
  chown interacted badly enough to surface as `stat: cannot statx … Permission
  denied` (couldn't reproduce locally; only ever seen in CI). The
  `$GITHUB_WORKSPACE` subdir sidesteps it entirely.

- `chmod g+rwx "$TESTDIR"` — runner is GHA UID 1001; act will run inside as a
  non-1001 UID per the recipe → needs group write to seed the workspace.

- `sudo rm -rf` cleanup — act chowned the contents to its `--user` target,
  see [[project-act-chowns-workspace-to-user]].

**How to apply:** any future "test that `act --bind` does X under UID Y" step
should follow this skeleton. The two existing steps (`Bind-mode host-UID
recipe`, `Bind-mode arbitrary-UID via nss_wrapper`) are the canonical pair —
duplicate one and tweak `UID:GID` + the inner workflow file + the assertion.
