---
name: actionlint-wrapper-quirks
description: raven-actions/actionlint@v2 flag parser preserves literal `"` chars; actionlint's `-ignore` matches Error.Message (not the `[rule-tag]` suffix).
metadata:
  type: project
---

Two gotchas when tuning actionlint suppressions in `.github/workflows/test-and-publish.yml`:

1. **Wrapper flag parser preserves quote chars.** `raven-actions/actionlint@v2` splits `with.flags` via `/(?:[^\s"]+|"[^"]*")+/g` and pushes the matched token verbatim (no quote-stripping) to argv. So `flags: -ignore "constant expression"` passes literal `"`-chars through to actionlint, which then treats them as part of the regex and never matches. Workaround: pick a no-space regex using `.` for the space, e.g. `flags: -ignore constant.expression`.

2. **`-ignore <regex>` matches `Error.Message`, not the formatted output.** The `[if-cond]` suffix in the rendered error line is NOT part of the matched string. So `-ignore if-cond` is a no-op against the if-cond rule's findings — you have to match a substring of the actual error wording (`constant expression "false" in condition.`).

**Why:** Hit both during the `prepare` composite-action rollout (PR #59). First push shipped `-ignore if-cond` and the 2 if-cond errors still failed CI. Second push tried `-ignore "constant expression"` and still failed because of the quote-preservation quirk. `-ignore constant.expression` finally stuck.

**How to apply:** When adding new actionlint exemptions in this repo, pick a no-space regex from a unique substring of the actual error message. Verify by reading the actionlint step's log output — it echoes `INPUT_FLAGS:` plus the argv vector it constructs, so you can confirm the regex reaches actionlint un-mangled before re-pushing.

**actionlint does NOT shellcheck a container body.** A `run:` block's shell is
linted, but the script inside `docker run … sh -c '…'` is a single-quoted
string to actionlint, so nothing in it is checked. On PR #109 the SAME defect
(`export X="$(...)"`, SC2155) existed at nine call sites and actionlint flagged
only the three that run directly on the runner — fixing just the reported ones
would have left six wrong and silent. When a lint finding names a pattern you
copy-pasted, grep the whole repo for the pattern rather than fixing the
reported line numbers. [[feedback_complete_set_needs_the_real_artifact]]
