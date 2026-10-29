# syntax=mirror.gcr.io/docker/dockerfile:1
# Docker Hub's official Ubuntu through Google's pull-through mirror, the registry the syntax line
# above already pulls from. It dodges both anonymous quotas that have broken this build: Docker Hub's
# pull rate limit, and AWS ECR Public's data limit, which 429'd every run on 2026-10-26
# (`toomanyrequests: Data limit exceeded`) and no rerun can clear. The rest of the pipeline
# builds/pulls via GHCR, so CI still does zero Docker Hub pulls.
# Renovate keeps the default pinned; the workflow_call path overrides OS_VERSION for on-demand
# requests targeting a different Ubuntu (e.g. 22.04). Default = current consumer pin.
ARG OS_VERSION=26.04
FROM mirror.gcr.io/library/ubuntu:${OS_VERSION} AS ubuntu-gnu-coreutils

# GNU coreutils in place of uutils, and uutils purged. Ubuntu 26.04 ships uutils: one 11.8 MB Rust
# multicall that also parses its Fluent locale files on every exec, so `uname -s` costs 4.7-5.1 ms
# CPU against GNU's 1.8-2.3. Playwright's pw_run.sh execs five of these per WebKit launch, which
# made our launch 1.08-1.13x official's (24.04, GNU) on the very same browser binaries, and the
# swap brought it to 1.04. GitHub's ubuntu-latest ships GNU too. Releases without uutils
# (22.04, 24.04) have no rust-coreutils and skip this.
RUN if dpkg -s rust-coreutils >/dev/null 2>&1; then \
      apt-get update \
      && apt-get install -y --no-install-recommends --allow-remove-essential \
         coreutils-from-gnu coreutils-from-uutils- \
      && apt-get purge -y --allow-remove-essential rust-coreutils \
      && rm -rf /var/lib/apt/lists/* \
      && [ "$(readlink -f /usr/bin/uname)" = /usr/bin/gnuuname ]; \
    fi

# Flattened, because uutils lives in the base image's own layer: purging it in a layer on top
# would only add whiteouts and ship the 16 MB anyway. The base's config is restated below.
FROM scratch
COPY --from=ubuntu-gnu-coreutils / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CMD ["/bin/bash"]

# Mimics GitHub's ubuntu-latest VM environment (accounts, env, OS-level tooling) per issue #5.
# Deliberately NO docker and NO language runtimes — those live in the docker/ overlay and the
# node|pnpm|playwright layers, so they stay independently versioned.
LABEL org.opencontainers.image.description="Ubuntu 24.04 mimicking GitHub Actions ubuntu-latest (users, env, OS tools; no docker, no runtimes)"

ENV DEBIAN_FRONTEND=noninteractive

# Static, tool-present env vars from the runner-images spec (issue #5). Heavy-SDK env
# (CONDA / ANDROID_* / JAVA_HOME_* / vcpkg / *WEBDRIVER) is intentionally omitted — those tools
# aren't installed, so advertising the paths would be misleading.
ENV LANG=C.UTF-8 \
    CI=true \
    ImageOS=ubuntu24 \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

# Deliberately NOT installed (unlike actions/runner-images ubuntu-24.04 — see README):
#  - the C/C++ toolchain (build-essential): ~106 MB compressed dead weight in this shared base since
#    most jobs never compile. Native-addon builds use the `-gyp` variant (e.g. {os}-{mode}-pnpm-gyp).
#  - shellcheck: ~14 MB dev-only shell linter nothing invokes at runtime; `apt install shellcheck` it.
RUN echo "OS-level tools: a curated subset of actions/runner-images ubuntu-24.04 (no runtimes/SDKs)" \
    && apt-get update && apt-get install -y --no-install-recommends \
       apt-utils \
       pkg-config \
       git \
       curl \
       wget \
       ca-certificates \
       gnupg \
       lsb-release \
       software-properties-common \
       locales \
       jq \
       zip \
       unzip \
       xz-utils \
       bzip2 \
       zstd \
       lz4 \
       p7zip-full \
       file \
       tree \
       rsync \
       openssh-client \
       dnsutils \
       net-tools \
       iputils-ping \
       netcat-openbsd \
       parallel \
       brotli \
       time \
       sudo \
       libnss-wrapper \
       python3 \
       python-is-python3 \
    && rm -rf /var/lib/apt/lists/* \
    \
    && echo "Set the same users as GitHub's ubuntu-latest" \
    && (userdel -r $(getent passwd 1000 | cut -d: -f1) 2>/dev/null || true) \
    && (userdel -r $(getent passwd 1001 | cut -d: -f1) 2>/dev/null || true) \
    && (userdel -r packer 2>/dev/null || true) \
    && (userdel -r runner 2>/dev/null || true) \
    && useradd -m -s /bin/bash -u 1000 -c "Ubuntu" packer \
    && echo "packer ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/packer \
    && chmod 0440 /etc/sudoers.d/packer \
    && useradd -m -s /bin/bash -u 1001 -c ",,," runner \
    && echo "%runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner \
    && chmod 0775 /home/runner \
    && usermod -aG adm,users,systemd-journal runner \
    \
    && echo "Tool cache dir, as on the hosted runner (RUNNER_TOOL_CACHE)" \
    && mkdir -p /opt/hostedtoolcache \
    && chown -R 1001:1001 /opt/hostedtoolcache \
    && chmod 2775 /opt/hostedtoolcache

# nss_wrapper helper: synthesises a /etc/passwd + /etc/group entry for an arbitrary
# host UID at runtime, for tools that call getpwuid()/getgrgid() directly. Opt-in by
# sourcing the script in a workflow step. Does NOT fix `sudo` (setuid strips
# LD_PRELOAD). See dood/README.md. Inlined here (vs COPY) because the build context
# is this per-image dir, not the repo root — kept identical to alpine-gha-tools.
RUN <<'EOF' bash
cat > /usr/local/bin/nss-wrapper-setup <<'SCRIPT'
#!/bin/sh
# Synthesise a /etc/passwd + /etc/group entry for the running UID/GID when one is
# missing, so getpwuid()/getgrgid()-using tools find a name. No-op when the UID
# already has an entry (root/packer/runner). See dood/README.md.
uid=$(id -u)
gid=$(id -g)
if getent passwd "$uid" >/dev/null 2>&1; then
  return 0 2>/dev/null || exit 0
fi
NSS_WRAPPER_PASSWD=${NSS_WRAPPER_PASSWD:-/tmp/.nss-passwd}
NSS_WRAPPER_GROUP=${NSS_WRAPPER_GROUP:-/tmp/.nss-group}
cp -f /etc/passwd "$NSS_WRAPPER_PASSWD"
cp -f /etc/group  "$NSS_WRAPPER_GROUP"
printf 'runner:x:%s:%s:CI host user:/home/runner:/bin/bash\n' "$uid" "$gid" >> "$NSS_WRAPPER_PASSWD"
# Prepended, not assigned: the alpine node layers preload mimalloc image-wide, and replacing
# LD_PRELOAD would drop it for every later step.
for cand in /usr/lib/x86_64-linux-gnu/libnss_wrapper.so /usr/lib/libnss_wrapper.so; do
  [ -e "$cand" ] && LD_PRELOAD=$cand${LD_PRELOAD:+:$LD_PRELOAD} && break
done
export NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP LD_PRELOAD
SCRIPT
chmod 0755 /usr/local/bin/nss-wrapper-setup
EOF

ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache

# Match the hosted runner's default cwd. GHA's `container:` overrides via
# `docker exec -w $GITHUB_WORKSPACE`, and act --bind sets its own workdir
# — both ignore this. Only affects `docker run` use (interactive sanity
# checks, dood bind-mode when the consumer hasn't passed `-w` explicitly).
WORKDIR /home/runner
USER runner
# Default CMD inherits from the base image (bash on ubuntu).
