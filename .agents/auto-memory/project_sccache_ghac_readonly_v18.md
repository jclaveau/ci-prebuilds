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

**2026-08-24 — CORRECTED: this is fixed at sccache 0.16.0. The backend works.**
The repo now installs 0.16.0 (`Dockerfile.setup`) and exports
`ACTIONS_CACHE_SERVICE_V2=1` in `ninja-resume.sh`. Real stats off a round:

    Compile requests 2260   Cache hits 30 (1.33 %)   Cache misses 2230
    Cache read errors   0   Cache write errors 210   Cache location: ghac

So reads and writes both function — the "0 writes, read-only" state above is
specific to 0.15 + opendal ≤0.51 and must not be quoted as current. What is
still open is the 210 write errors (~9% of misses) and, more importantly,
whether a SECOND cold build actually hits: 1.33% on an empty cache says
nothing, and no full-length round has ever reported
([[feedback_report_from_trap_not_after_the_call]] — the stats line sat after
the `timeout`, so only rounds that died early ever printed).
