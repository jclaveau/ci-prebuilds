# syntax=docker/dockerfile:1
# Alpine official image mirrored on AWS ECR Public (NOT Docker Hub) to avoid Docker Hub's pull rate
# limit in CI: the rest of the pipeline builds/pulls via GHCR, so CI does zero Docker Hub pulls.
# Renovate keeps the default pinned; the workflow_call path overrides OS_VERSION for on-demand
# requests targeting a different Alpine (e.g. 3.20). Default = current consumer pin.
ARG OS_VERSION=3.21
FROM public.ecr.aws/docker/library/alpine:${OS_VERSION}

# Alpine/musl counterpart of ubuntu-gha-tools: the same accounts, env, curated OS tooling and the
# interactive bash sugar (ll/la/l) so the developer environment is identical across both flavors.
# Deliberately NO docker and NO language runtimes — those live in the docker/ overlay and the
# node|pnpm|playwright layers, so they stay independently versioned.
LABEL org.opencontainers.image.description="Alpine 3.21 mirroring the ubuntu-gha-tools dev env (users, env, OS tools, bash sugar; no docker, no runtimes)"

ENV LANG=C.UTF-8 \
    CI=true \
    ImageOS=alpine3.21 \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

# `shadow` provides useradd/usermod/userdel so the account setup matches ubuntu-gha-tools verbatim;
# `coreutils` gives GNU ls/etc. so the `ll` family behaves like Ubuntu's (not the busybox applets).
# apt-only packages (apt-utils, lsb-release, software-properties-common, locales) and `time` are
# dropped (N/A on Alpine/musl); python-is-python3 becomes a python->python3 symlink.
# Deliberately NOT installed (mirrors ubuntu-gha-tools — see README): the C/C++ toolchain (build-base,
# ~compressed dead weight; use the `-gyp` variant for native addons) and shellcheck (dev-only linter,
# `apk add shellcheck` it if you lint shell).
RUN echo "OS-level tools: Alpine equivalents of the ubuntu-gha-tools curated set (no runtimes/SDKs)" \
    && apk add --no-cache \
       bash \
       bash-completion \
       coreutils \
       shadow \
       sudo \
       pkgconf \
       git \
       curl \
       wget \
       ca-certificates \
       gnupg \
       jq \
       zip \
       unzip \
       xz \
       bzip2 \
       zstd \
       lz4 \
       p7zip \
       file \
       tree \
       rsync \
       openssh-client \
       bind-tools \
       net-tools \
       iputils \
       netcat-openbsd \
       parallel \
       brotli \
       python3 \
       nss_wrapper \
    && ln -sf python3 /usr/bin/python \
    \
    && echo "Interactive bash sugar matching Ubuntu's default skel (.bashrc holds the aliases; .profile" \
    && echo "sources .bashrc for login shells) so ll/la/l work the same in docker run / act" \
    && mkdir -p /etc/skel \
    && printf '%s\n' \
        "alias ls='ls --color=auto'" \
        "alias grep='grep --color=auto'" \
        "alias ll='ls -alF'" \
        "alias la='ls -A'" \
        "alias l='ls -CF'" \
        >> /etc/skel/.bashrc \
    && printf '%s\n' \
        'if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi' \
        >> /etc/skel/.profile \
    \
    && echo "Set the same users as GitHub's ubuntu-latest (packer 1000, runner 1001) with bash + sudo" \
    && (userdel -r "$(getent passwd 1000 | cut -d: -f1)" 2>/dev/null || true) \
    && (userdel -r "$(getent passwd 1001 | cut -d: -f1)" 2>/dev/null || true) \
    && useradd -m -s /bin/bash -u 1000 -c "Ubuntu" packer \
    && echo "packer ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/packer \
    && chmod 0440 /etc/sudoers.d/packer \
    && useradd -m -s /bin/bash -u 1001 -c ",,," runner \
    && echo "%runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner \
    && chmod 0775 /home/runner \
    && usermod -aG wheel runner \
    \
    && echo "Tool cache dir, as on the hosted runner (RUNNER_TOOL_CACHE)" \
    && mkdir -p /opt/hostedtoolcache \
    && chown -R 1001:1001 /opt/hostedtoolcache \
    && chmod 2775 /opt/hostedtoolcache

# nss_wrapper helper: synthesises a /etc/passwd + /etc/group entry for an arbitrary
# host UID at runtime, for tools that call getpwuid()/getgrgid() directly. Opt-in by
# sourcing the script in a workflow step. Does NOT fix `sudo` (setuid strips
# LD_PRELOAD). See dood/README.md. Inlined here (vs COPY) because the build context
# is this per-image dir, not the repo root — kept identical to ubuntu-gha-tools.
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
for cand in /usr/lib/x86_64-linux-gnu/libnss_wrapper.so /usr/lib/libnss_wrapper.so; do
  [ -e "$cand" ] && LD_PRELOAD=$cand && break
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
# Default CMD inherits from the base image (sh on alpine).
