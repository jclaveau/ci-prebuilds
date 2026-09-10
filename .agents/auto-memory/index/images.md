# images — docker layering, dind/dood, UID handling, strip passes

Full hooks for this area. The routing keys live in `.agents/auto-memory/MEMORY.md`; the memories themselves in `.agents/auto-memory/<slug>.md`.

- [Strip before the final COPY, not after](project_strip_must_precede_final_copy.md) — layer blobs are immutable, so post-COPY `rm` never shrinks the published image; staging stage moved alpine 897→794 MiB (7bd4ab6); measure compressed layer sums, never `du`
- [All-3-browsers alpine image](project_all_browsers_alpine_image.md) — chs+ff+wk headless in Dockerfile.alpine; WebKit needs seccomp=unconfined + WEBKIT_DISABLE_SANDBOX; PW host-req validation false-positives on musl (libGLESv2/libx264 "missing" though ldd-clean) → PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
- [dind sudoers named paths that don't exist](project_dind_sudoers_paths_unmatched.md) — /usr/sbin/dockerd, /usr/bin/chown on Alpine; rules never matched, only the hardened flavour would expose it; now `command -v` at build time
- [Docker engine moved out of dood into dind](project_docker_engine_out_of_dood.md) — dood can't use a local daemon; 794 → 719 MiB, engine is 157 MiB of the shared base
- [Consumer strip extension: runner parity + libvpx exception](project_strip_extension_runner_parity.md) — `248f01c` strips NSS/codecs/WPE-core/crypto (ff 73 / wk 78 libs + Mesa); conformance runner applies the SAME strip (tested==shipped), FF+WK edge conformance 21/21 green; libvpx stays bundled (edge apk vpx lacks mozilla's symbol set → un-validatable)
- [act --bind host-UID recipe](project_act_bind_host_uid_recipe.md) — `--user $(id -u):$(id -g) --group-add 1001 -e HOME=/home/runner` to avoid 1001-owned files on the host
- [act chowns workspace to --user target](project_act_chowns_workspace_to_user.md) — TP cleanup needs `sudo rm -rf` when act target UID ≠ runner UID
- [Alpine has no historical apk archive](project_alpine_no_historical_apk_archive.md) — dl-cdn 404s old pkgver; aports MR pipelines skip artifacts; no date-snapshotted edge — drift-warn and ship is the only viable strategy
- [Per-image Docker build context](project_docker_build_context_per_image.md) — `COPY` resolves from `./<image>/`, not repo root; inline shared scripts via BuildKit heredoc
- [DOCKER_MODE env convention](project_docker_mode_env.md) — `ENV DOCKER_MODE=dind|dood` baked into leaf overlays; inherits through every derived layer; smoke-tested
- [GHA runner UID = image runner UID = 1001](project_gha_runner_uid_is_1001.md) — naive `--user $(id -u)` is a no-op on GHA; pick UID 1000 or 5000 to actually exercise overrides
- [ICU dedup must be a relative symlink, not a hardlink](project_icu_dedup_symlink_not_hardlink.md) — CI buildkitd v0.31.2 (docker-container driver) exports cross-layer hardlinks as regular copies, undoing the ~5.7M dedup; fixed af6a232 via pure-bash relative `ln -s`; strip layer 2,028,594→2,525 B; default builder hides the bug
- [nss_wrapper scope (A vs B)](project_nss_wrapper_scope.md) — LD_PRELOAD env fixes cosmetic getpwuid; sudo needs `/etc/ld.so.preload` (Ubuntu-only, invasive)
- [pnpm chmod-EPERM is upstream](project_pnpm_chmod_eperm_upstream.md) — pnpm/pnpm#3699: `linkBin` re-chmods existing global bins; POSIX chmod is owner-or-root; no image-side fix possible; consumer workaround is gated `sudo chown`
- [PNPM_HOME split design rejected](project_pnpm_home_split_rejected.md) — runtime+build PNPM_HOME isolation rejected: transitive-dep dedup re-exposes the chmod trap on shared store inodes
- [sudo requires getpwuid](project_sudo_requires_getpwuid.md) — sudo refuses unresolvable UIDs ("you do not exist in the passwd database"); not Alpine-specific
- [TP bind-test pattern](project_tp_bind_test_pattern.md) — use `$GITHUB_WORKSPACE/_bind-test*` subdirs (not `mktemp -d`); `chmod g+rwx` + `sudo rm -rf` cleanup
