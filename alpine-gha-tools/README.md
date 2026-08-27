# alpine-gha-tools

Alpine 3.21 set up to mirror [`ubuntu-gha-tools`](../ubuntu-gha-tools/README.md) as closely as
musl/Alpine allows — the lightweight foundation for the `alpine-*` flavor of every other image here.

## Usage

Published as `jclaveau/alpine-gha-tools` on Docker Hub. Tags: `:latest` and version-pinned
`:alpine3.21`. The `-sudoer` flavor lives at `jclaveau/alpine-gha-tools-sudoer` (see
[hardened vs sudoer](../README.md#hardened-default-and--sudoer-flavors)).

```yaml
jobs:
  shell-job:
    runs-on: ubuntu-latest
    container: jclaveau/alpine-gha-tools:latest
    steps:
      - uses: actions/checkout@v4
      - run: jq --version && git --version
```

Locally: `docker run --rm -it jclaveau/alpine-gha-tools:latest bash`.

Need Docker / Node / pnpm / Playwright? Pick a downstream layer — see
[the image table at the root](../README.md#pick-your-image).

## What it adds
- **Accounts** matching the hosted runner: `runner` (uid 1001) and `packer` (uid 1000), both with
  passwordless `sudo` (via the `shadow` + `sudo` packages, so the user setup is identical to Ubuntu's).
- **Environment**: `LANG=C.UTF-8`, `CI=true`, `ImageOS=alpine3.21`,
  `RUNNER_TOOL_CACHE=/opt/hostedtoolcache` (+ `AGENT_TOOLSDIRECTORY`), and the `/opt/hostedtoolcache` dir.
- **OS-level tools** — the Alpine (`apk`) equivalents of the ubuntu-gha-tools curated set:
  pkgconf, git, curl, wget, gnupg, jq, zip/unzip, xz/bzip2/zstd/lz4, p7zip, rsync, openssh-client,
  bind-tools, python3, … (see the `Dockerfile` for the full list).
- **Bash sugar** — `bash` + `coreutils` + the same interactive aliases as Ubuntu's default shell
  (`ll`/`la`/`l`, colored `ls`/`grep`), installed via `/etc/skel` so `runner` gets them on `docker run`
  / `act`. CI asserts these are identical to ubuntu-gha-tools.

## What's deliberately omitted (and why)
Mirrors [`ubuntu-gha-tools`](../ubuntu-gha-tools/README.md): the **C/C++ toolchain** (`build-base`) and
**`shellcheck`** are dropped to keep this shared base slim — they'd otherwise weigh down every
downstream image. Native-addon builds use the **`-gyp` variant**
([`{os}-{mode}-pnpm-gyp`](../pnpm-gyp/README.md), which adds `build-base`); `apk add shellcheck` in
your job if you lint shell.

## What it implies
- **No Docker and no language runtimes** — those are added by the [`docker`](../docker/README.md) overlay
  and the [`node`](../node/README.md) / [`pnpm`](../pnpm/README.md) / [`playwright`](../playwright/README.md)
  layers, so each stays independently versioned.
- **musl, not glibc.** A handful of apt-only packages (`lsb-release`, `software-properties-common`,
  `locales`, `time`) have no Alpine counterpart and are dropped; some downstream layers diverge more
  (notably Playwright, whose three browsers are built from source against musl rather than
  taken from the system packages).
- In **GitHub Actions container jobs the steps run as root** (uid 0), ignoring the image's `USER runner`.
  The baked accounts/env/aliases matter for `docker run` / `act`, not inside a GHA job.
- Published; tagged `latest` and a version-pinned `alpineXX.YY` (e.g. `alpine3.21`) on each push to main.
