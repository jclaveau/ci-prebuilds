---
name: project_dood_host_docker_gids
description: dood images join a group per GitHub-hosted docker gid (112/113/118) because a container job keeps the host socket's gid and replaces the entrypoint; shipped PR #354 dbefb88 2026-11-05, closes #353
metadata:
  type: project
---

The docker socket a dood container job sees keeps the HOST's docker gid:
ubuntu-24.04 118, ubuntu-26.04 113, 112 on runner build 20261018.50.1.
The image used to bake only the gid of the runner that BUILT it
(`getent group docker` in the github-context job), so an image built on 24.04
and run on 26.04 got EACCES on /var/run/docker.sock.

GHA container jobs replace the entrypoint with `tail`, so no runtime step can
re-align the gid. Fix (docker/Dockerfile + Dockerfile.alpine, 645f2dd):
`ARG DOCKER_HOST_GROUP_IDS="112 113 118"`, `groupadd -o docker-host-<gid>` and
add runner + packer to each. PR run 41944786579 green on 26.04 gid 112 and 113.

**How to apply:** a new runner image with an unseen docker gid → EACCES on the
socket in dood jobs; add the gid to DOCKER_HOST_GROUP_IDS (probe it the way
2f983f4's tmp-dood-gid-probe.yml did). Docker 29's containerd store reports
driver `overlayfs`; the act dood smoke accepts it (fab028d).
