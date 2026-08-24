---
name: feedback_merge_without_review_here
description: on ci-prebuilds jean does not review — merge my own green PRs myself instead of parking them for approval
metadata:
  type: feedback
---

On **this repo only**, jean does not do PR reviews. His words: *"why don't you
merge this, i don't do reviews on this repo, i just add CI steps providing
numbers for you to loop"*. A green PR of mine is mine to merge, and mine to
follow through: merge → dispatch whatever producer it feeds → read the numbers
→ act on them.

The green bar still holds. He waived the *review*, not
[[feedback_never_merge_nongreen_pr]] — and PR-time green is not build green
here, since every browser build is dispatch- or label-gated. A merged PR has
proven nothing until its producer has run.

**Why:** I had #101/#102/#103 sitting green and "awaiting your review" for a
day, and put them at the top of a tally as though the ball were in his court.
It was not. His role on ci-prebuilds is to build the measuring apparatus; the
loop that consumes the measurements is mine to close.

**How to apply:** open the PR for the record (the body is where the reasoning
lives), let CI go green, merge it, then dispatch. Only stop and ask when the
question is genuinely his — a product/UX call, an irreversible action, a
tradeoff no measurement settles ([[feedback_never_pause_unless_blocked]]).
Does NOT generalize: everywhere else [[feedback_no_merge_without_review]] and
[[feedback_ask_before_branch_switch_and_pr]] still stand, per
[[feedback_scope_memory_by_what_varies]].

**Extended 2026-08-24:** *"loop until no more ready to merge pr needs to be
merged."* The remit is the whole PR queue, not only mine — Renovate's included.
"Ready" means green AND not stale AND the change is actually sound; each of
those failed on a different PR the same evening:

- **stale green** — #97 green from 83 commits back; rebased for a fresh run
  ([[feedback_pr_green_is_stale_after_base_moves]]).
- **conflicting** — #98 and #101 had each appended at the same point in
  `prep-source.sh`; kept BOTH blocks and proved it with zero deletions against
  either parent.
- **sound? no** — #71 was mergeable and would have broken every `apt-get`
  ([[feedback_bump_target_may_be_dead]]). Resolving a PR can mean CLOSING it
  with the evidence and fixing the bot that produced it.

Drained 7 that evening: merged #97 #98 #105 #106 #107 #79, closed #71. Only the
parked draft #37 was left. Parked/draft PRs stay parked
([[feedback_superseded_label_not_close]]).

