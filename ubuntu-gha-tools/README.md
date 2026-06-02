# ubuntu-gha-tools

Ubuntu 24.04 set up to mimic GitHub's `ubuntu-latest` runner environment — the shared foundation every
other image in this repo builds on.

## Usage

Published as `jclaveau/ubuntu-gha-tools` on Docker Hub. Tags: `:latest` and version-pinned
`:ubuntu24.04`. The `-sudoer` flavor lives at `jclaveau/ubuntu-gha-tools-sudoer` (see
[hardened vs sudoer](../README.md#hardened-default-and--sudoer-flavors)).

```yaml
jobs:
  shell-job:
    runs-on: ubuntu-latest
    container: jclaveau/ubuntu-gha-tools:latest
    steps:
      - uses: actions/checkout@v4
      - run: jq --version && git --version
```

Locally: `docker run --rm -it jclaveau/ubuntu-gha-tools:latest bash`.

Need Docker / Node / pnpm / Playwright? Pick a downstream layer instead — see
[the image table at the root](../README.md#pick-your-image).

## What it adds
- **Accounts** matching the hosted runner: `runner` (uid 1001) and `packer` (uid 1000), both with
  passwordless `sudo`.
- **Environment**: `LANG=C.UTF-8`, `CI=true`, `ImageOS=ubuntu24`,
  `RUNNER_TOOL_CACHE=/opt/hostedtoolcache` (+ `AGENT_TOOLSDIRECTORY`), and the `/opt/hostedtoolcache` dir.
- **OS-level tools** — a curated subset of [`actions/runner-images`](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md):
  pkg-config, git, curl, wget, gnupg, jq, zip/unzip, xz/bzip2/zstd/lz4, p7zip, rsync,
  openssh-client, dnsutils, python3, … (see the `Dockerfile` for the full list).

## What's deliberately omitted (and why)
Unlike GitHub's `ubuntu-latest`, this base does **not** ship:
- **the C/C++ build toolchain** (`build-essential` — gcc/g++/make): ~106 MB compressed that every
  downstream image (`docker`, `dood`/`dind`, `node`, `pnpm`, `playwright`) would carry, while most CI
  jobs never compile native code. Builds that *do* need it use the **`-gyp` variant**
  (e.g. [`{os}-{mode}-pnpm-gyp`](../pnpm-gyp/README.md)), which adds the toolchain back.
- **`shellcheck`** (~14 MB): a dev-only shell linter nothing invokes at runtime. `apt install shellcheck`
  in your job if you lint shell.

The only cost is strict `ubuntu-latest` parity — a workflow that compiles native modules works on the
hosted runner but needs the `-gyp` image here. This is the deliberate trade that keeps the base slim.

## What it implies
- **No Docker and no language runtimes** — those are added by the [`docker`](../docker/README.md) overlay
  and the [`node`](../node/README.md) / [`pnpm`](../pnpm/README.md) / [`playwright`](../playwright/README.md)
  layers, so each stays independently versioned.
- In **GitHub Actions container jobs the steps run as root** (uid 0), ignoring the image's `USER runner`,
  and GitHub injects its own `RUNNER_TOOL_CACHE`/`ImageOS`. The baked accounts/env matter for
  `docker run` / `act`, not inside a GHA job.
- Published; tagged `latest` and a version-pinned `ubuntuXX.YY` (e.g. `ubuntu24.04`) on each push to main.
