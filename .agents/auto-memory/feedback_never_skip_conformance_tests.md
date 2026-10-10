---
name: feedback_never_skip_conformance_tests
description: HARD RULE — never add a skip (title, file, needs-headed, any list or annotation) to the Playwright conformance suite; jean will never allow one, not even for test-version skew
metadata:
  type: feedback
---

Adding a conformance skip of any kind is forbidden. That covers skip-list/*.titles.txt,
*.files.txt, needs-headed lists, --grep-invert patterns and test edits, and it
applies to every browser. Never add one, never propose one, and don't offer it as
an option for jean to choose.

A red conformance test gets fixed in the browser, the runner or the version pins:
- make the browser behave the way the pinned client expects. Example: the
  storage.getDirectory skew on the 1e9d2b1f WebKit, where the new WebKit returns
  UnknownError on Linux and the 1.62.1 test expects TypeError off-Mac.
- align the client/test version with the browser.
- or report the red and leave it red.

**Why:** jean, 2026-10-09: "you are never allowed and we will never allow a skip on
conformance tests". This came after I proposed a one-line skip for
storage.getDirectory as a promote unblocker.
**How to apply:** this outranks [[feedback_gate_on_measured_capability_not_skip_list]]
in this repo. That memory's probe-derived exclusions are still skips: do not add new
ones. Leave the existing lists alone, and don't remove entries without an ask either.
Related: [[project_wk_1e9d2b1f_auth_protocol_skew]].
