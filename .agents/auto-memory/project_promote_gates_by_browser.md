---
name: project_promote_gates_by_browser
description: the three browser promote jobs had three DIFFERENT gates (firefox too strict, chromium apk too loose) — unified to webkit's shape in PR #157
metadata:
  type: project
---

**RESOLVED 2026 (PR #157).** All three promote jobs now read the same shape:
`on main, and (push | dispatch-with-this-browser-on)`, each need spelled out
explicitly rather than relying on `!cancelled()` to imply it (that operator
waives the failed-need skip for the WHOLE needs list at once, not just the
one you're waiving it for — see [[feedback_gha_skipped_chain_not_cancelled_guard]]).

The two bugs #157 fixed were in opposite directions:
- **firefox was too strict** — `push && ref == main` only, so a fully green
  dispatch (all smokes, 20/20 conformance) could never ship; this is why
  `ff-latest` went stale while dispatches kept passing clean.
- **chromium's apk promote was too loose** — the `github.ref == main` check
  sat *inside* the push arm only, so a `workflow_dispatch` from ANY branch
  still published the moving `chs-apk-*` tags. Same defect webkit had before
  its own fix.

`promote-firefox.yml`'s dispatch path (added same window) exists specifically
so an arm branch can be probed and, once proven, promoted without a second
main-only rebuild — see [[project_source_tag_probe_pattern]].

**Below is the pre-#157 state, kept for the historical incident it describes:**

| job | gate (superseded) |
|---|---|
| `promote-firefox` | `push && ref == refs/heads/main` — branch builds can never ship |
| `promote-webkit` | `!cancelled()` + finalize/smoke/conformance success + (dispatch with `build_webkit=true` OR push-to-main) |
| `promote-chromium-headless-shell-from-source` | `!cancelled()` + build/smoke/conformance success + **`event_name == 'workflow_dispatch'`** — no branch condition |

So a dispatched from-source chromium that goes green **promotes `chs-<rev>` /
`chs-<ver>` / `chs-latest` on GHCR *and* Docker Hub from any branch**. Run
32262979614 did exactly that off `feat/pw-1.62.1-sweep` (2026-08-21), and I had
told jean it was main-gated.

**Why:** I read `.github/workflows/playwright-alpine-browsers.yml` from the
working tree (on `main`) while the run used the branch's copy, where the job
exists with a different gate. WebKit's gate has the same dispatch clause, so a
green WebKit dispatch would move `wk-latest` the same way.

**How to apply:**
- Before saying a job will/won't run, read the workflow **at the run's head sha**
  (`gh api repos/O/R/contents/<path>?ref=<sha>`), never the local checkout.
- Treat a green dispatch of chromium-from-source or webkit as a PUBLISH.
- `promote-firefox.yml` (added 2026-08-21) is the dispatch path Firefox lacked;
  it re-implements the gates as pre-flights. See [[feedback_never_merge_nongreen_pr]].

**It happened, and twice in eight minutes (2026-08-21).** The two chromium perf
arms finished together and each promoted: PGO `a649cb7` took `chs-latest` at
13:40:05, ThinLTO `b689c01` overwrote it at 13:47:51, displacing the main-lineage
`911c93b`. So `chs-latest` is decided by whichever experiment finishes last, not
by what we ship. Both were green (conformance 20/20 + smoke), so nothing broke and
nothing warned. Pinned `chs-<rev>` tags were unaffected. Parked for a fix in
`.agents/requested-memory/parked_chromium_promote_and_pgo_comment.md`.
