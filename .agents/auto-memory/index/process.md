# process — how to work in this repo

Full hooks for this area. The routing keys live in `.agents/auto-memory/MEMORY.md`; the memories themselves in `.agents/auto-memory/<slug>.md`.

- [Merge my own green PRs here — jean does not review](feedback_merge_without_review_here.md) — he builds the CI that produces the numbers; closing the loop (merge → dispatch → read → act) is mine; green bar still holds and PR-green ≠ build-green
- [Check a source-only patch reaches the build](project_source_patch_reaches_build_checklist.md) — before a multi-hour dispatch: image tag sha-scoped? script COPYed before the RUN that invokes it? a wrong answer ships a green build without the fix
- [Autonomous CI-fix loop](feedback_autonomous_ci_loop.md) — iterate amend + `push --force-with-lease` to main until CI green without checking in; monitor prompt-free via the allow-listed `pnpm ci:watch`; keep amends file-scoped
- [Prefer pnpm ci:logs](feedback_prefer_pnpm_ci_logs.md) — for diagnosing latest CI failures, `pnpm ci:logs` (no args, auto-detects latest failed job in latest run) is preferred over raw `gh api .../jobs/<id>/logs` which prompts every time
- [READMEs: link parents, don't duplicate](feedback_readme_no_parent_duplication.md) — derived image READMEs cross-ref parent sections via anchor; only document what the layer itself contributes
- [Tally output includes GHA run URL](feedback_tally_include_run_url.md) — every iteration tally appends current in_progress run URL (or latest completed if none) so user can jump straight in
- [Pre-v1 doc style: skip stale historical refs](project_pre_v1_doc_style.md) — ci-prebuilds is pre-v1; drop refs like `(actions/runner#266)` when the fix is GA and stable; keep open upstream bugs and in-flight discussions
- [Similar projects landscape](reference_similar_projects.md) — adjacent repos (catthehacker, official Playwright/pnpm/docker:dind images, ARC); none do this repo's exact dood+dind layered matrix
