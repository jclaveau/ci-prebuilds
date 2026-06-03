---
name: autonomous-ci-loop
description: "How Jean wants CI-fix iteration handled — autonomous amend+force-push loop, prompt-free monitoring via a pnpm ci:watch script"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 3f0ef504-2d86-4db0-ab57-675965af3665
---

When fixing CI for the `github-action-container-images` repo, Jean delegates the whole iterate-until-green loop: stage → `git commit --amend --no-edit` → `git push --force-with-lease origin main` → watch CI → diagnose failure → fix → repeat, **without checking in between iterations**. Only report on success or a genuine blocker (e.g. registry outage, a decision that needs their call).

**Why:** Jean keeps the whole feature on a single squashed commit (e.g. "feat: true dind and dood") and force-pushes amended versions to `main` — this is their deliberate solo-repo workflow, not something to warn about each time. They got tired of being pinged after every CI run.

**How to apply:**
- Force-pushing to `main` is authorized for this loop; use `--force-with-lease`. (Still warn once if asked to force-push in a *different* context.)
- Monitor CI prompt-free via the `pnpm ci:watch` script (root `package.json`, kept unstaged) which is allow-listed in `.claude/settings.local.json`. It finds the latest run, `gh run watch`es it, and prints the final job summary. Run it as a background task; the completion notification re-invokes you to continue the loop — no user prompt needed.
- Keep amends scoped to only the files that make CI pass. Do NOT sweep in unrelated changes (e.g. the README CI badge was explicitly reserved for a separate later commit). Stage files individually, never `git add -A`.
- The GHA CI logs API drops step **stdout** for these container jobs; route diagnostics to **stderr** or read the full log via the downloadable archive (`gh api .../runs/<id>/logs` → unzip).

See [[no_claude_folder]] for where project vs global content lives.
