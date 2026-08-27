---
name: project_bench_pulls_dockerhub_latest
description: benchmark-playwright pulls jclaveau/<scenario>-playwright from DOCKER HUB, so a fresh GHCR promote is invisible to it until a push to main republishes the consumer image
metadata:
  type: project
---

`benchmark-playwright.yml` is in DEV MODE: it pulls
`jclaveau/${SC}-playwright:${TAG}` from **Docker Hub**, defaulting to `latest`.
It does not read GHCR and it does not read `sha-*` tags.

So a browser promote is two hops away from the bench:

```
promote-webkit         -> ghcr wk-latest = <sha>          (dispatch, any branch)
push to main           -> test-and-publish rebuilds the consumer image,
                          COPYing the CURRENT wk-latest, and pushes Docker Hub latest
benchmark-playwright   -> pulls Docker Hub latest
```

**Why it matters.** On 2026-08-26 `wk-latest` was promoted at 14:40 UTC, but
Docker Hub `latest` still carried rev `b48d8c37` built at **10:34** — four hours
earlier. Dispatching the bench at that moment would have reproduced the exact red
it was meant to clear, and the natural reading would have been "the promote did
not work". The #117 merge push at 01:18 republished `latest` as `94d3ddd5` at
01:34, and the bench dispatched right after came back fully green.

**How to apply:** before benching a browser change, read the consumer tag's own
label and compare it against the promote you are trying to observe:

```
docker buildx imagetools inspect jclaveau/alpine-dood-playwright:latest \
  --format '{{json .Image}}'   # org.opencontainers.image.revision + .created
```

If it predates the promote, wait for (or trigger) a main push rather than
dispatching the bench. Sibling of [[feedback_verify_moving_tag_payload]] — a tag
being fresh is a claim, not proof — and of
[[project_promote_gates_by_browser]].
