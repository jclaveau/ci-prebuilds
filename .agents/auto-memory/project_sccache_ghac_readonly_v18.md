---
name: project_sccache_ghac_readonly_v18
description: sccache ghac (GHA cache API) backend rejects writes with "Cannot write to read-only storage" using ACTIONS_RUNTIME_TOKEN from workflow env
metadata:
  type: project
---

sccache 0.15's `ghac` backend calling GHA cache v2 endpoint returns write-refused per compile. r2 stats: 2791 compilations, 2791 write errors, 0 writes, 0 hits.

Log payload from v18 r2 job 84790371894:
- `sccache::server] Error executing cache write: Cannot write to read-only storage`
- `opendal ghac ... /_apis/artifactcache/cache?keys=... => 404 page not found` on reads (cache empty because writes never landed)
- Every compile: `cache_write_errors: N; cache_writes: 0`

**Why:** sccache 0.15 + opendal <=0.51 target the OLD ACC v1 path `/_apis/artifactcache/cache` on the NEW v2 host `results-receiver.actions.githubusercontent.com`. GH deprecated v1 early 2025 (v2 uses Twirp `/twirp/github.actions.results.api.v1.CacheService/*`). Every request 404s. On writes, opendal's ghac backend flips into RO state after the reserve-cache-entry POST fails, surfacing the misleading "Cannot write to read-only storage" — an opendal-side error, not a GHA token/scope issue.

**How to apply:** On v19 chromium-from-source, sccache-ghac is dead until sccache/opendal ships v2 Twirp support. Options:
1. Ditch sccache — rely purely on Docker layer cache-to via intermediate images (already proven working: multi-job cross-image handoff r1→r2)
2. Swap backend to S3/GCS: `SCCACHE_BUCKET=s3://... + AWS_ACCESS_KEY_ID/SECRET` from repo secrets
3. Wait for/pin newer sccache with opendal >=0.53 that speaks the v2 Twirp path; try `SCCACHE_GHA_VERSION=2` if the build honors it

Related: [[project_buildkit_cacheto_commit_semantics]] (why we moved to multi-job in the first place). Even without sccache cross-round hits, the per-round Docker layer of accumulated `obj/*.o` DOES persist across jobs (proven r1→r2 delta).
