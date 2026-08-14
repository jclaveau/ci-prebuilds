# CI + registry metrics

- runs: **2110** (2025-10-17 -> 2026-08-14)
- jobs: **76137**, **2513** runner-hours total
- tagged image versions priced: **5051**, deduped GHCR footprint **905.4 GB** (sum of per-image pull sizes: 5222.8 GB)
- artifacts on record: **15144**, **4.7 GB**, **9120** already expired

## Weekly cost

| week | runner-hours | top workflow | GHCR added | GHCR live |
|---|---:|---|---:|---:|
| 2025-10-13 | 0.7 | Build and Push Docker Images | 0.0 GB | 0.0 GB |
| 2025-10-20 | 6.2 | Build and Push Docker Images | 0.0 GB | 0.0 GB |
| 2026-05-25 | 138.3 | Benchmark Playwright | 9.5 GB | 9.5 GB |
| 2026-06-01 | 312.0 | Test and Publish | 185.2 GB | 194.7 GB |
| 2026-06-08 | 186.7 | Playwright Alpine Browsers | 65.7 GB | 260.4 GB |
| 2026-06-15 | 263.9 | Playwright Alpine Browsers | 68.4 GB | 328.8 GB |
| 2026-06-22 | 290.1 | Playwright Alpine Browsers | 38.0 GB | 366.8 GB |
| 2026-06-29 | 136.9 | Playwright Alpine Browsers | 62.2 GB | 429.0 GB |
| 2026-07-06 | 213.1 | Playwright Alpine Browsers | 101.3 GB | 530.3 GB |
| 2026-07-13 | 302.6 | Playwright Alpine Browsers | 110.9 GB | 641.2 GB |
| 2026-07-20 | 154.8 | Playwright Alpine Browsers | 29.2 GB | 670.4 GB |
| 2026-07-27 | 158.3 | Playwright Alpine Browsers | 76.6 GB | 747.1 GB |
| 2026-08-03 | 95.8 | Playwright Alpine Browsers | 27.0 GB | 774.0 GB |
| 2026-08-10 | 254.0 | Playwright Alpine Browsers | 131.4 GB | 905.4 GB |

## What this would cost as a private repo

Standard runners are free on public repos, so today this is all $0. Privately it is almost entirely Actions minutes, because the registry is exempt: *"Container image storage and bandwidth for the Container registry is currently free."*

| month | billed minutes | Actions $ |
|---|---:|---:|
| 2025-10 | 715 | $4 |
| 2026-05 | 13,464 | $81 |
| 2026-06 | 80,321 | $482 |
| 2026-07 | 59,876 | $359 |
| 2026-08 | 27,852 | $167 |
| **total** | **182,228** | **$1,093** |

Artifact storage: **2.2 GB-months** = **$1** at $0.25/GB/month.

Net of each plan's included minutes, per month averaged over the 5 month(s) on record:

| plan | included | billed over | $/month |
|---|---:|---:|---:|
| Free | 2,000 | 34,446 | $207 |
| Pro | 3,000 | 33,446 | $201 |
| Team | 3,000 | 33,446 | $201 |
| Enterprise | 50,000 | 0 | $0 |

Registry exposure if the exemption ends: **905 GB** at $0.25/GB/month = **$226/month**, which would roughly double the bill. GitHub commits to one month's notice, so it is a watch item rather than a plan.

## Image pull size, per package

| package | images | first | latest | min | max |
|---|---:|---:|---:|---:|---:|
| alpine-dind | 404 | 237 MB | 125 MB | 125 MB | 237 MB |
| alpine-dind-playwright | 361 | 562 MB | 771 MB | 326 MB | 1091 MB |
| alpine-dood | 412 | 237 MB | 72 MB | 72 MB | 237 MB |
| alpine-dood-playwright | 365 | 561 MB | 719 MB | 326 MB | 1091 MB |
| alpine-gha-tools | 495 | 134 MB | 51 MB | 49 MB | 134 MB |
| playwright-alpine-browsers | 82 | 100 MB | 137 MB | 100 MB | 137 MB |
| ubuntu-dind | 413 | 349 MB | 263 MB | 238 MB | 349 MB |
| ubuntu-dind-playwright | 365 | 1008 MB | 935 MB | 882 MB | 1008 MB |
| ubuntu-dood | 415 | 349 MB | 173 MB | 173 MB | 349 MB |
| ubuntu-dood-playwright | 367 | 1008 MB | 844 MB | 844 MB | 1008 MB |
| ubuntu-gha-tools | 451 | 203 MB | 116 MB | 114 MB | 203 MB |

## Median seconds, per week

| series | week | time-to-tests | test time |
|---|---|---:|---:|
| bench act-alpine-dind-gyp/all | 2026-07-27 | - | 47 |
| bench act-alpine-dind-gyp/all | 2026-08-03 | - | 44 |
| bench act-alpine-dind-gyp/all | 2026-08-10 | - | 45 |
| bench act-alpine-dind-gyp/chromium | 2026-05-25 | - | 21 |
| bench act-alpine-dind-gyp/chromium | 2026-07-27 | - | 36 |
| bench act-alpine-dind-gyp/chromium | 2026-08-03 | - | 34 |
| bench act-alpine-dind-gyp/chromium | 2026-08-10 | - | 33 |
| bench act-alpine-dind/all | 2026-07-27 | - | 43 |
| bench act-alpine-dind/all | 2026-08-03 | - | 41 |
| bench act-alpine-dind/all | 2026-08-10 | - | 42 |
| bench act-alpine-dind/chromium | 2026-05-25 | - | 19 |
| bench act-alpine-dind/chromium | 2026-07-27 | - | 33 |
| bench act-alpine-dind/chromium | 2026-08-03 | - | 30 |
| bench act-alpine-dind/chromium | 2026-08-10 | - | 31 |
| bench act-alpine-dood-gyp/all | 2026-07-27 | - | 48 |
| bench act-alpine-dood-gyp/all | 2026-08-03 | - | 45 |
| bench act-alpine-dood-gyp/all | 2026-08-10 | - | 44 |
| bench act-alpine-dood-gyp/chromium | 2026-05-25 | - | 21 |
| bench act-alpine-dood-gyp/chromium | 2026-07-27 | - | 35 |
| bench act-alpine-dood-gyp/chromium | 2026-08-03 | - | 34 |
| bench act-alpine-dood-gyp/chromium | 2026-08-10 | - | 34 |
| bench act-alpine-dood/all | 2026-07-27 | - | 43 |
| bench act-alpine-dood/all | 2026-08-03 | - | 41 |
| bench act-alpine-dood/all | 2026-08-10 | - | 42 |
| bench act-alpine-dood/chromium | 2026-05-25 | - | 19 |
| bench act-alpine-dood/chromium | 2026-07-27 | - | 33 |
| bench act-alpine-dood/chromium | 2026-08-03 | - | 30 |
| bench act-alpine-dood/chromium | 2026-08-10 | - | 30 |
| bench act-baseline/all | 2026-05-25 | - | 72 |
| bench act-baseline/chromium | 2026-05-25 | - | 46 |
| bench act-official-gyp/all | 2026-05-25 | - | 58 |
| bench act-official-gyp/all | 2026-07-27 | - | 64 |
| bench act-official-gyp/all | 2026-08-03 | - | 56 |
| bench act-official-gyp/all | 2026-08-10 | - | 62 |
| bench act-official-gyp/chromium | 2026-05-25 | - | 51 |
| bench act-official-gyp/chromium | 2026-07-27 | - | 54 |
| bench act-official-gyp/chromium | 2026-08-03 | - | 49 |
| bench act-official-gyp/chromium | 2026-08-10 | - | 56 |
| bench act-official/all | 2026-05-25 | - | 39 |
| bench act-official/all | 2026-07-27 | - | 52 |
| bench act-official/all | 2026-08-03 | - | 47 |
| bench act-official/all | 2026-08-10 | - | 52 |
| bench act-official/chromium | 2026-05-25 | - | 31 |
| bench act-official/chromium | 2026-07-27 | - | 45 |
| bench act-official/chromium | 2026-08-03 | - | 41 |
| bench act-official/chromium | 2026-08-10 | - | 43 |
| bench act-ours-alpine/chromium | 2026-05-25 | - | 21 |
| bench act-ours-ubuntu/all | 2026-05-25 | - | 43 |
| bench act-ours-ubuntu/chromium | 2026-05-25 | - | 34 |
| bench act-ubuntu-dind-gyp/all | 2026-05-25 | - | 43 |
| bench act-ubuntu-dind-gyp/all | 2026-07-27 | - | 45 |
| bench act-ubuntu-dind-gyp/all | 2026-08-03 | - | 43 |
| bench act-ubuntu-dind-gyp/all | 2026-08-10 | - | 44 |
| bench act-ubuntu-dind-gyp/chromium | 2026-05-25 | - | 35 |
| bench act-ubuntu-dind-gyp/chromium | 2026-07-27 | - | 38 |
| bench act-ubuntu-dind-gyp/chromium | 2026-08-03 | - | 36 |
| bench act-ubuntu-dind-gyp/chromium | 2026-08-10 | - | 37 |
| bench act-ubuntu-dind/all | 2026-05-25 | - | 40 |
| bench act-ubuntu-dind/all | 2026-07-27 | - | 41 |
| bench act-ubuntu-dind/all | 2026-08-03 | - | 42 |
| bench act-ubuntu-dind/all | 2026-08-10 | - | 42 |
| bench act-ubuntu-dind/chromium | 2026-05-25 | - | 33 |
| bench act-ubuntu-dind/chromium | 2026-07-27 | - | 34 |
| bench act-ubuntu-dind/chromium | 2026-08-03 | - | 34 |
| bench act-ubuntu-dind/chromium | 2026-08-10 | - | 34 |
| bench act-ubuntu-dood-gyp/all | 2026-05-25 | - | 43 |
| bench act-ubuntu-dood-gyp/all | 2026-07-27 | - | 45 |
| bench act-ubuntu-dood-gyp/all | 2026-08-03 | - | 43 |
| bench act-ubuntu-dood-gyp/all | 2026-08-10 | - | 44 |
| bench act-ubuntu-dood-gyp/chromium | 2026-05-25 | - | 35 |
| bench act-ubuntu-dood-gyp/chromium | 2026-07-27 | - | 37 |
| bench act-ubuntu-dood-gyp/chromium | 2026-08-03 | - | 36 |
| bench act-ubuntu-dood-gyp/chromium | 2026-08-10 | - | 36 |
| bench act-ubuntu-dood/all | 2026-05-25 | - | 40 |
| bench act-ubuntu-dood/all | 2026-07-27 | - | 42 |
| bench act-ubuntu-dood/all | 2026-08-03 | - | 41 |
| bench act-ubuntu-dood/all | 2026-08-10 | - | 43 |
| bench act-ubuntu-dood/chromium | 2026-05-25 | - | 32 |
| bench act-ubuntu-dood/chromium | 2026-07-27 | - | 34 |
| bench act-ubuntu-dood/chromium | 2026-08-03 | - | 33 |
| bench act-ubuntu-dood/chromium | 2026-08-10 | - | 33 |
| bench alpine-dind-gyp/all | 2026-07-27 | 35 | 15 |
| bench alpine-dind-gyp/all | 2026-08-03 | 41 | 11 |
| bench alpine-dind-gyp/all | 2026-08-10 | 31 | 15 |
| bench alpine-dind-gyp/chromium | 2026-05-25 | 20 | 3 |
| bench alpine-dind-gyp/chromium | 2026-07-27 | 32 | 4 |
| bench alpine-dind-gyp/chromium | 2026-08-03 | 31 | 5 |
| bench alpine-dind-gyp/chromium | 2026-08-10 | 32 | 5 |
| bench alpine-dind/all | 2026-07-27 | 33 | 14 |
| bench alpine-dind/all | 2026-08-03 | 28 | 14 |
| bench alpine-dind/all | 2026-08-10 | 28 | 16 |
| bench alpine-dind/chromium | 2026-05-25 | 18 | 3 |
| bench alpine-dind/chromium | 2026-07-27 | 35 | 4 |
| bench alpine-dind/chromium | 2026-08-03 | 31 | 5 |
| bench alpine-dind/chromium | 2026-08-10 | 28 | 5 |
| bench alpine-dood-gyp/all | 2026-07-27 | 35 | 15 |
| bench alpine-dood-gyp/all | 2026-08-03 | 33 | 16 |
| bench alpine-dood-gyp/all | 2026-08-10 | 29 | 16 |
| bench alpine-dood-gyp/chromium | 2026-05-25 | 20 | 3 |
| bench alpine-dood-gyp/chromium | 2026-07-27 | 37 | 4 |
| bench alpine-dood-gyp/chromium | 2026-08-03 | 32 | 4 |
| bench alpine-dood-gyp/chromium | 2026-08-10 | 28 | 4 |
| bench alpine-dood/all | 2026-07-27 | 34 | 15 |
| bench alpine-dood/all | 2026-08-03 | 29 | 15 |
| bench alpine-dood/all | 2026-08-10 | 28 | 15 |
| bench alpine-dood/chromium | 2026-05-25 | 18 | 3 |
| bench alpine-dood/chromium | 2026-07-27 | 31 | 4 |
| bench alpine-dood/chromium | 2026-08-03 | 35 | 4 |
| bench alpine-dood/chromium | 2026-08-10 | 26 | 5 |
| bench baseline-gyp/all | 2026-05-25 | 46 | 15 |
| bench baseline-gyp/all | 2026-07-27 | 58 | 13 |
| bench baseline-gyp/all | 2026-08-03 | 64 | 10 |
| bench baseline-gyp/all | 2026-08-10 | 54 | 14 |
| bench baseline-gyp/chromium | 2026-05-25 | 26 | 3 |
| bench baseline-gyp/chromium | 2026-07-27 | 29 | 3 |
| bench baseline-gyp/chromium | 2026-08-03 | 25 | 3 |
| bench baseline-gyp/chromium | 2026-08-10 | 29 | 3 |
| bench baseline/all | 2026-05-25 | 50 | 15 |
| bench baseline/all | 2026-07-27 | 50 | 15 |
| bench baseline/all | 2026-08-03 | 53 | 15 |
| bench baseline/all | 2026-08-10 | 53 | 14 |
| bench baseline/chromium | 2026-05-25 | 26 | 3 |
| bench baseline/chromium | 2026-07-27 | 28 | 3 |
| bench baseline/chromium | 2026-08-03 | 24 | 3 |
| bench baseline/chromium | 2026-08-10 | 26 | 3 |
| bench official-gyp/all | 2026-05-25 | 48 | 10 |
| bench official-gyp/all | 2026-07-27 | 62 | 10 |
| bench official-gyp/all | 2026-08-03 | 46 | 11 |
| bench official-gyp/all | 2026-08-10 | 54 | 10 |
| bench official-gyp/chromium | 2026-05-25 | 44 | 3 |
| bench official-gyp/chromium | 2026-07-27 | 57 | 2 |
| bench official-gyp/chromium | 2026-08-03 | 54 | 3 |
| bench official-gyp/chromium | 2026-08-10 | 53 | 3 |
| bench official/all | 2026-05-25 | 30 | 10 |
| bench official/all | 2026-07-27 | 54 | 9 |
| bench official/all | 2026-08-03 | 38 | 10 |
| bench official/all | 2026-08-10 | 43 | 10 |
| bench official/chromium | 2026-05-25 | 30 | 3 |
| bench official/chromium | 2026-07-27 | 50 | 3 |
| bench official/chromium | 2026-08-03 | 39 | 3 |
| bench official/chromium | 2026-08-10 | 42 | 3 |
| bench ours-alpine/chromium | 2026-05-25 | 20 | 3 |
| bench ours-ubuntu/all | 2026-05-25 | 34 | 10 |
| bench ours-ubuntu/chromium | 2026-05-25 | 34 | 2 |
| bench ours/alpine | 2026-05-25 | 20 | 4 |
| bench ours/ubuntu | 2026-05-25 | 35 | 6 |
| bench ubuntu-dind-gyp/all | 2026-05-25 | 34 | 10 |
| bench ubuntu-dind-gyp/all | 2026-07-27 | 38 | 11 |
| bench ubuntu-dind-gyp/all | 2026-08-03 | 36 | 10 |
| bench ubuntu-dind-gyp/all | 2026-08-10 | 37 | 10 |
| bench ubuntu-dind-gyp/chromium | 2026-05-25 | 34 | 2 |
| bench ubuntu-dind-gyp/chromium | 2026-07-27 | 37 | 3 |
| bench ubuntu-dind-gyp/chromium | 2026-08-03 | 35 | 2 |
| bench ubuntu-dind-gyp/chromium | 2026-08-10 | 37 | 3 |
| bench ubuntu-dind/all | 2026-05-25 | 32 | 10 |
| bench ubuntu-dind/all | 2026-07-27 | 45 | 8 |
| bench ubuntu-dind/all | 2026-08-03 | 39 | 11 |
| bench ubuntu-dind/all | 2026-08-10 | 35 | 10 |
| bench ubuntu-dind/chromium | 2026-05-25 | 32 | 2 |
| bench ubuntu-dind/chromium | 2026-07-27 | 35 | 3 |
| bench ubuntu-dind/chromium | 2026-08-03 | 33 | 3 |
| bench ubuntu-dind/chromium | 2026-08-10 | 34 | 3 |
| bench ubuntu-dood-gyp/all | 2026-05-25 | 34 | 10 |
| bench ubuntu-dood-gyp/all | 2026-07-27 | 40 | 10 |
| bench ubuntu-dood-gyp/all | 2026-08-03 | 32 | 10 |
| bench ubuntu-dood-gyp/all | 2026-08-10 | 36 | 10 |
| bench ubuntu-dood-gyp/chromium | 2026-05-25 | 34 | 2 |
| bench ubuntu-dood-gyp/chromium | 2026-07-27 | 38 | 3 |
| bench ubuntu-dood-gyp/chromium | 2026-08-03 | 46 | 2 |
| bench ubuntu-dood-gyp/chromium | 2026-08-10 | 37 | 3 |
| bench ubuntu-dood/all | 2026-05-25 | 32 | 10 |
| bench ubuntu-dood/all | 2026-07-27 | 36 | 10 |
| bench ubuntu-dood/all | 2026-08-03 | 32 | 10 |
| bench ubuntu-dood/all | 2026-08-10 | 33 | 10 |
| bench ubuntu-dood/chromium | 2026-05-25 | 32 | 2 |
| bench ubuntu-dood/chromium | 2026-07-27 | 36 | 3 |
| bench ubuntu-dood/chromium | 2026-08-03 | 35 | 3 |
| bench ubuntu-dood/chromium | 2026-08-10 | 34 | 3 |
| conformance chromium-headless-shell | 2026-06-22 | 15 | 100 |
| conformance chromium-headless-shell | 2026-06-29 | 16 | 81 |
| conformance chromium-headless-shell | 2026-07-06 | 23 | 81 |
| conformance chromium-headless-shell-from-source | 2026-07-06 | 20 | 126 |
| conformance chromium-headless-shell-from-source | 2026-07-13 | 26 | 93 |
| conformance chromium-headless-shell-from-source | 2026-07-27 | 26 | 144 |
| conformance chromium-headless-shell-from-source | 2026-08-03 | 26 | 141 |
| conformance chromium-headless-shell-from-source | 2026-08-10 | 25 | 118 |
| conformance firefox | 2026-07-06 | 27 | 136 |
| conformance firefox | 2026-07-13 | 31 | 126 |
| conformance firefox | 2026-07-20 | 30 | 148 |
| conformance firefox | 2026-08-10 | 33 | 201 |
| conformance ubuntu-chromium | 2026-07-06 | 2 | 119 |
| conformance ubuntu-chromium | 2026-07-13 | 2 | 115 |
| conformance ubuntu-chromium | 2026-07-20 | 3 | 123 |
| conformance ubuntu-chromium | 2026-07-27 | 3 | 124 |
| conformance ubuntu-chromium | 2026-08-03 | 3 | 126 |
| conformance ubuntu-chromium | 2026-08-10 | 3 | 123 |
| conformance ubuntu-firefox | 2026-07-06 | 2 | 167 |
| conformance ubuntu-firefox | 2026-07-13 | 2 | 161 |
| conformance ubuntu-firefox | 2026-07-20 | 2 | 163 |
| conformance ubuntu-firefox | 2026-08-10 | 3 | 188 |
| conformance ubuntu-webkit | 2026-07-06 | 2 | 212 |
| conformance ubuntu-webkit | 2026-07-13 | 2 | 156 |
| conformance ubuntu-webkit | 2026-07-20 | 3 | 159 |
| conformance ubuntu-webkit | 2026-08-03 | 3 | 194 |
| conformance webkit | 2026-07-06 | 34 | 191 |
| conformance webkit | 2026-07-13 | 38 | 135 |
| conformance webkit | 2026-07-20 | 66 | 142 |
| conformance webkit | 2026-08-03 | 61 | 192 |
