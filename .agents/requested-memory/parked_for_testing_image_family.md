---
name: parked_for_testing_image_family
description: PARKED 2026-09-24 by jean — every lever that trades real security for speed goes into a future chr-for-testing / ffx-for-testing / wk-for-testing image family whose contract explicitly states lower security, testing use only; BackupRefPtr-off is the first resident, joined by the Thorium parked tweaks and the other below-official candidates from #259; the default published images keep official's hardening
metadata:
  type: project
---

**Ruling (2026-09-24), user-initiated.** Asked whether dropping
BackupRefPtr weakens the built browser; told yes, and that it goes *below*
official rather than toward it. Verdict: **park it, do not drop the lever
— give it a home.**

> "Park it with the other parked tweaks listed from Thorium. We will
> gather all those in our chr-for-testing / ffx-for-testing /
> wk-for-testing which will explicitely allow lower security for perf as
> only intended for testing"

**The family.** A separate published image line — `chr-for-testing`,
`ffx-for-testing`, `wk-for-testing` — whose stated contract is that it
trades memory-safety and hardening mitigations for speed and is intended
for test execution only. That contract is what makes these levers
shippable: the objection to BRP-off was never the measurement, it was
publishing a browser with the UAF mitigation silently off under the same
tag consumers already pull. A distinct name and an explicit statement
removes the "silently".

**The default images do not change.** `chs-latest` and the per-browser
shipped tags keep official's hardening. Anything in this family is opt-in
by tag.

**Residents (gathered here, none dispatched):**

- **BackupRefPtr off** (`enable_backup_ref_ptr_support = false`) — issue
  #259 candidate 2. The largest single memory-safety removal on the list:
  `raw_ptr<T>` carries a refcount in the PartitionAlloc header and
  quarantines a slot freed while still referenced, turning a UAF into a
  crash instead of a groomable primitive. Upstream default is ON for
  linux x64 official (`enable_backup_ref_ptr_support = use_partition_alloc
  && enable_backup_ref_ptr_support_default`), so official pays it too.
  The auto-mode classifier refuses the edit as `[Security Weaken]` —
  correctly; it will need jean's explicit go in-session when the family
  is built.
- **libc++ hardening NONE** (`enable_safe_libcxx = false`) — the stronger
  half of #259 candidate 3. The FAST half is a normal parity candidate
  and is already in flight on `perf/chromium-libcxx-fast`; NONE belongs
  here.
- **SSP off**, **`_FORTIFY_SOURCE` off**, **UBSan array-bounds/return
  traps off** — #259 candidates 4, 5, 7.
- **The Thorium `-mllvm` lore flags** (`-enable-gvn-hoist`,
  `-aggressive-ext-opt`, `-enable-pre=false`) — not a security trade but
  a *correctness* one (RobRich999-lineage flags with an upstream
  miscompile history), which is the same reason they can't ride the
  default tag. [[project_chromium_thorium_audit]] #3.
- **`-march=x86-64-v3`** — no security cost at all, but SIGILLs on
  pre-Haswell, so it needs an opt-in tag for exactly the same reason.
  Currently in flight as a parity *measurement* on
  `perf/chromium-march-v3`; if it wins, the shipping question lands here
  rather than on the default tag.

**Still NOT candidates, in this family or any other:** sandbox and
site-isolation. They protect the test process and change behavior PW
tests may depend on — the exclusion from
[[project_chromium_hardening_removal_candidates]] carries over unchanged.

**How to apply:** when a `*-for-testing` line is actually built, this is
the shopping list and the rationale for the tag's README/label text. Until
then, none of these get added to `args.gn.overlay` on a default-tag
branch. Measurement on a candidate branch is fine and does not require the
family to exist first — publishing does.
