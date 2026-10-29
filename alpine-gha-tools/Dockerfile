# syntax=mirror.gcr.io/docker/dockerfile:1
# Docker Hub's official Alpine through Google's pull-through mirror, the registry the syntax line
# above already pulls from. It dodges both anonymous quotas that have broken this build: Docker Hub's
# pull rate limit, and AWS ECR Public's data limit, which 429'd every run on 2026-10-26
# (`toomanyrequests: Data limit exceeded`) and no rerun can clear. The rest of the pipeline
# builds/pulls via GHCR, so CI still does zero Docker Hub pulls.
# Renovate keeps the default pinned; the workflow_call path overrides OS_VERSION for on-demand
# requests targeting a different Alpine (e.g. 3.20). Default = current consumer pin.
ARG OS_VERSION=3.24

# GNU coreutils as one binary per program, the way Debian/Ubuntu ship it, swapped in over Alpine's
# `coreutils` package (#350). Alpine builds it as ONE multicall /bin/coreutils with every library any
# program needs linked into it — libcrypto, libacl, libattr, libutmps, libskarnet — so even `true`
# loads all five on each exec. Here each program links only what it uses: the hash tools libcrypto,
# ls/cp/mv libacl+libattr. Same box, 1000 execs, CPU-ms: true 2700 → 856, cat 2827 → 958,
# ls 3127 → 1138 (busybox true 981). openssl stays on (Alpine's --with-openssl): without it
# sha256sum on 50 MB went 0.198 → 0.479 s.
# Same version, tarball and configure as Alpine's APKBUILD (main/coreutils, 3.24-stable) — the
# sha512 below is the one it pins — minus three things: the single binary, utmps (who/pinky/users
# read musl's always-empty utmp instead; a container has no utmps daemon to ask anyway), and -Os,
# Alpine's size default, for -O2. A bump goes with the Alpine `coreutils` package of the release,
# taking that APKBUILD's sha512.
FROM mirror.gcr.io/library/alpine:${OS_VERSION} AS coreutils-build
ARG COREUTILS_VERSION=9.11
ARG COREUTILS_SHA512=73f4192747ab793fd29cccafeda35c499a11800830227ea4d26b00afb2c496dd69cb493005691d0f62a168beea6b55c1e28e82b6cf795e7370f9d53d13555410
RUN apk add --no-cache build-base acl-dev attr-dev openssl-dev linux-headers perl bash curl
RUN set -eu \
    && cd /tmp \
    && curl -fsSLO "https://ftp.gnu.org/gnu/coreutils/coreutils-${COREUTILS_VERSION}.tar.xz" \
    && echo "${COREUTILS_SHA512}  coreutils-${COREUTILS_VERSION}.tar.xz" | sha512sum -c - \
    && tar -xf "coreutils-${COREUTILS_VERSION}.tar.xz" \
    && cd "coreutils-${COREUTILS_VERSION}" \
    && fu_cv_sys_stat_statvfs=n \
       FORCE_UNSAFE_CONFIGURE=1 \
       CONFIG_SHELL=/bin/bash \
       CFLAGS="-O2 -fstack-clash-protection -Wformat -Werror=format-security -flto=auto" \
       ./configure \
         --prefix=/usr \
         --disable-nls \
         --enable-no-install-program=hostname,su,kill,uptime \
         --with-openssl \
    && make -j"$(nproc)" \
    && make install DESTDIR=/tmp/coreutils-install
# Lays our programs out at the exact paths Alpine's packages put theirs (/bin/ls, /usr/bin/sha256sum,
# /usr/sbin/chroot, …), read from the package file lists, so the swap below replaces every one and
# moves nothing. A program Alpine ships that this build lacks fails here, not as a missing command.
RUN set -eu \
    && apk add --no-cache coreutils \
    && apk info -qL coreutils coreutils-env coreutils-fmt coreutils-sha512sum \
       | grep -v -e '^$' -e ' contains:$' -e '/coreutils$' -e '^usr/share/' >/tmp/alpine-coreutils-paths \
    && while read -r alpine_path; do \
         program_name=${alpine_path##*/}; \
         case "$alpine_path" in \
           usr/libexec/*) built_path=/tmp/coreutils-install/usr/libexec/coreutils/$program_name ;; \
           *) built_path=/tmp/coreutils-install/usr/bin/$program_name ;; \
         esac; \
         [ -f "$built_path" ] || { echo "Alpine ships /$alpine_path, this build has no $built_path" >&2; exit 1; }; \
         install -D -m 0755 "$built_path" "/coreutils-swap/$alpine_path"; \
       done </tmp/alpine-coreutils-paths \
    && strip /coreutils-swap/bin/* /coreutils-swap/usr/bin/* /coreutils-swap/usr/sbin/* \
    && for crypto_program in /coreutils-swap/bin/* /coreutils-swap/usr/bin/* /coreutils-swap/usr/sbin/*; do \
         case "${crypto_program##*/}" in \
           md5sum|sha*sum|b2sum|cksum) ;; \
           *) if ldd "$crypto_program" | grep -q libcrypto; then \
                echo "${crypto_program##*/} links libcrypto; only the hash tools should" >&2; exit 1; \
              fi ;; \
         esac; \
       done \
    && ldd /coreutils-swap/usr/bin/sha256sum | grep -q libcrypto \
    && wc -l </tmp/alpine-coreutils-paths

FROM mirror.gcr.io/library/alpine:${OS_VERSION}

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
# `coreutils` gives GNU ls/etc. so the `ll` family behaves like Ubuntu's (not the busybox applets);
# its multicall binary is then swapped for the per-program build above.
# `tar` is GNU tar: actions/cache shells out to `tar --posix … --use-compress-program zstdmt`, which
# busybox rejects ("unrecognized option: posix") on BOTH restore and save, each time as a warning —
# so a container job stays green while losing every cache entry it downloads and every one it writes.
# apt-only packages (apt-utils, lsb-release, software-properties-common, locales) and `time` are
# dropped (N/A on Alpine/musl); python-is-python3 becomes a python->python3 symlink.
# Deliberately NOT installed (mirrors ubuntu-gha-tools — see README): the C/C++ toolchain (build-base,
# ~compressed dead weight; use the `-gyp` variant for native addons) and shellcheck (dev-only linter,
# `apk add shellcheck` it if you lint shell).
RUN --mount=type=bind,from=coreutils-build,source=/coreutils-swap,target=/tmp/coreutils-swap \
    echo "OS-level tools: Alpine equivalents of the ubuntu-gha-tools curated set (no runtimes/SDKs)" \
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
       tar \
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
    && echo "Swap Alpine's multicall coreutils for the per-program build: rename(2) over each symlink," \
    && echo "with busybox's mv, so no step runs a coreutils program while its own path is replaced" \
    && /bin/busybox cp -a /tmp/coreutils-swap/. /coreutils-swap-staged/ \
    && (cd /coreutils-swap-staged && /bin/busybox find . -type f) | while read -r swap_path; do \
         /bin/busybox mv -f "/coreutils-swap-staged/$swap_path" "/$swap_path"; \
       done \
    && /bin/busybox rm -rf /coreutils-swap-staged /bin/coreutils \
    && for linked_path in /bin/* /sbin/* /usr/bin/* /usr/sbin/*; do \
         [ -L "$linked_path" ] || continue; \
         case "$(readlink "$linked_path")" in \
           *coreutils) echo "$linked_path still points at the removed multicall /bin/coreutils" >&2; exit 1 ;; \
         esac; \
       done \
    && ls --version | head -1 \
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
# Default CMD inherits from the base image (sh on alpine).
