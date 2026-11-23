---
name: project_consumer_tarball_export_ignore
description: a consumer's uses:…@v0 downloads the repo tarball, which honours export-ignore; 1.3MB/707 entries for a 15KB action until .gitattributes whitelists the action dir
metadata:
  type: project
---

`uses: jclaveau/ci-prebuilds/.github/actions/prepare@v0` makes the runner download the
**whole repository tarball** for that ref, not just the action's directory. The codeload
tarball honours `export-ignore`, so `.gitattributes` is the only lever on what a consumer
pays.

Measured on `v0` at `ceb3f7e`, before the whitelist: **1.3MB, 707 entries** to run an
action that is **4 files, 15.5KB**. Planner has 9 `prepare@v0` uses, one per workflow.

**The probe that proves the mechanism**, rather than trusting the docs: `metrics/` is in
the tag's tree but absent from the published tarball, so the repo's single pre-existing
`/metrics export-ignore` line was already working.

```sh
git ls-tree --name-only v0 | grep '^metrics$'              # present in the tree
gh api repos/jclaveau/ci-prebuilds/tarball/v0 > v0.tar.gz
tar tzf v0.tar.gz | grep -c '/metrics/'                    # absent from the archive
```

A whitelist has no `!` form in `.gitattributes`; it is spelled **last-match-wins**, each
level ignoring its own entries then un-ignoring the one that leads on. A new top-level
directory is then excluded by the first line, with nothing to update:

```
/* export-ignore
/.github -export-ignore
/.github/* export-ignore
/.github/actions -export-ignore
/.github/actions/* export-ignore
/.github/actions/prepare -export-ignore
```

**Scope:** `export-ignore` applies to archives only. `actions/checkout` clones, so this
repo's own local `uses: ./.github/actions/...` steps, every test workflow and `build-layer`
are untouched — only a remote `uses:` of this repo pays the tarball. Verify with
`git archive --format=tar HEAD | tar t` on a commit, not on the worktree: `git archive`
reads `.gitattributes` from the tree it archives.

**Why it is safe here:** the only remotely consumed path is `prepare`, and the action reads
nothing outside its own dir — `prepare.js` spawns the store script via
`path.join(__dirname, 'pnpm-store.sh')`, and its other reads are the consumer's `.nvmrc`
and `package.json` through `workspaceFile()`.

**How to apply:** before export-ignoring anything, grep for every remote `uses:` of this
repo (consumers, not just this repo's own workflows), then re-probe the tarball after the
tag moves. See [[project_prepare_action_versioning]].
