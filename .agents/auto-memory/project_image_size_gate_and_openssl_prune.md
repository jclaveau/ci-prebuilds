---
name: project_image_size_gate_and_openssl_prune
description: image-size-gate (39507b6, 2026-11-06) fails promote when compressed amd64 grows >5% vs <image>-sudoer:latest; OpenSSL archs prune cut alpine node+ images 8.9 MiB compressed (alpine-dood-node 120.8 vs 129.7 MiB, 0.931x)
metadata:
  type: project
---

- Stage B node layer had grown 24 → 54 MiB compressed unnoticed; include/node/openssl/archs
  (21 platforms, 55.5 MiB, 3,090 files) was most of it. `node/prune-openssl-archs.sh` keeps
  only the machine's arch, in its own Dockerfile.alpine stage (a post-COPY rm never shrinks).
- Validation run 42187158618: alpine-dood-node 120.8 vs 129.7 MiB (0.931x), every alpine
  node+ image -8.9 MiB, ubuntu 1.000-1.003x. Saving is small compressed (headers compress),
  the gain is ~2,930 fewer files to extract.
- `scripts/image-size-gate.py` + `.github/image-size-allowances.tsv` (deliberate growth:
  `<image>\t<max_mib>\t<reason>`), job `image-size-gate` in promote's needs. Report splits
  same-step growth / candidate-only / baseline-only steps (a changed RUN text shows as both).

**How to apply:** an image growing on purpose needs an allowance line in the same commit;
delete it after the release publishes.
