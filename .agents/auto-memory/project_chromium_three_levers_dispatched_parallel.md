---
name: project_chromium_three_levers_dispatched_parallel
description: 2026-09-23 jean approved attacking chromium's nav/input residual with 3 levers at once — faststring 3-arm A/B (PR #306), a hash-mismatch flag probe (run 35909301424), and a self-PGO prerequisite check (same run); the ~60-80h cost estimate was WRONG (self-PGO needs no 2nd cold chain); flag probe 5a/5b FINISHED — the borrowed-profile foreign-hash argument for self-PGO is DEAD (residual TUs 4/4 resolved, 0.0% counts dropped on the snapshot-clang chain), self-PGO's only remaining rationale is workload fit, tested cheaply first on Firefox ([[project_ff_pgo_corpus_append_experiment]])
metadata:
  type: project
---

Following [[project_chromium_click_force_never_profiled]]'s musl-memset
finding, jean asked "a see no reason not to attack the 3 points in
parallel. Do you?" — agreed, with one real blocker checked before burning
runner time on it.

**Concurrency-group audit (the usual reason "parallel" silently
serializes here):**

| lever | workflow | group | collides? |
|---|---|---|---|
| faststring 3-arm | `chs-perf-ab` | per-pair suffix | no |
| self-PGO chromium | `playwright-alpine-browsers` | `pab-${ref}-chs-source` | no, **only if dispatched on its own branch** — on `main` it shares the lane with any other from-source dispatch |
| hash-mismatch flag probe | `chromium-build-flags-probe` | **no concurrency block at all** | never queues |

**Self-PGO chromium has an unchecked prerequisite — the exact failure
class that cost Firefox two days ([[project_ff_pgo_arm_mechanics]]):**
`chrome_pgo_phase=2` consumes a profile; generating one needs
`chrome_pgo_phase=1`, which needs clang's profile runtime
(`libclang_rt.profile.a`) for the target — missing on Alpine's clang22,
present on clang23 (proved by PR #298's roundtrip), but "probably" isn't
good enough in front of a 30h generate round. Cheap to settle first: ~40
min to compile one TU with `-fprofile-generate` in the chs build image and
confirm the runtime links.

**Second, larger, still-open unknown for self-PGO: chromium has no
equivalent of Firefox's `mach`-driven `profileserver.py`.** An instrumented
`headless_shell` has to be *driven* to produce profile counts — new
plumbing is needed to run the probe kernels against it and collect the
profraw, and *what* drives it (the probe kernels are the obvious choice,
since they're what's being optimized) is a design decision, not a flag
flip. Not dispatching the 30h build on the prerequisite answer alone until
this is resolved.

**Why chromium's PGO gap is structurally different from firefox's win
(0.74 geo, [[project_ff_pgo_arm_mechanics]]):** Firefox's profile is
self-generated on its own musl build with its own workload. Chromium's is
**borrowed** — `apply-and-build.sh:567-581` downloads Google's public
`chrome-linux-<branch>.profdata`, collected on glibc Chrome under Google's
browsing corpus, applied to a musl `headless_shell`. That's why
`is_cfi=true` is load-bearing (the CFG hash must match Google's,
[[project_chromium_pgo_hash_needs_cfi]]) and why 18 hot style/layout
functions still mismatch even with CFI on
(`Element::AttributeChanged` 62M counts, `RecalcOwnStyle` 19M,
`PseudoStateChanged` 10M). A self-generated profile has no foreign hash to
match, so the mismatch problem disappears rather than needing to be
narrowed — but at ~60-80h of runner time against Firefox's 6h05, it needs
the prerequisite + driver design settled first, not started on a whim.

**Dispatched 2026-09-23 19:26Z:** hash-mismatch probe + self-PGO
prerequisite as one run, **`35909301424`** (branch
`perf/chromium-pgo-variant-probe`, `6b87272`, reads fortify's cached r12
round image, no rebuild needed). The probe now tests something narrower
than "recompile and see": it reads the resolved cc1 line for `element.cc`,
reports which CFG-shaping flags are absent
(`-fwhole-program-vtables`, `-fsplit-lto-unit`, `-fno-semantic-interposition`,
`-fsanitize=cfi-mfcall`, `-fforce-emit-vtables`), then recompiles the 4
residual TUs once per absent flag (baseline first) — a drop in mismatch
count names the single flag. An error count rides along so a clang variant
that rejects a flag outright can't misread as a clean zero.

faststring's PR #306 — see [[project_chromium_faststring_moves_layout_text]]
"STATUS 2026-09-23" for the 3-arm design — 2 checks pending as of dispatch.

**How to apply:** before treating "parallel" as free, check each
workflow's `concurrency:` group for a shared lane; a lever with none never
queues (insurance-cheap to run even if redundant), a lever sharing a
branch-scoped lane needs its own branch to actually parallelize.

**2026-09-23, later: the 60-80h estimate was wrong (mine), corrected before
dispatch.** Jean asked what the FF PGO win implies for chromium; answering it
properly meant checking the assumption behind the cost figure instead of
repeating it.

1. **The residual 18 mismatched functions are not our patch to drop.** The
   only chromium source fix in this repo is `scripts/musl-source-fixes.sh`
   (29 lines, sqlite's ioctl cast only) — `element.cc`, `style_adjuster.cc`,
   `block_node.cc`, `block_layout_algorithm.cc` are untouched by us. Their
   CFG differs from Google's for structural reasons (different clang 22/23,
   musl vs glibc headers, `replace_gn_files.py --system-libraries` swapping
   headers inside templated/inlined code) — a campaign, not a one-liner.

2. **Self-PGO does not need two cold chains.** `args.gn.overlay` is `COPY`ed
   at `Dockerfile.setup:161` so editing *the overlay* does reseed r1..r12
   cold — but `apply-and-build.sh:595-614` already composes `args.gn` from
   the overlay **plus a build-time injection block** (`PGO_DATA_PATH`,
   `CHS_LLVM_VER`, `PW_CHROMIUM_ENABLE_DEBUG`, all from env, no file edit),
   and `ninja-resume.sh` already resumes from an older round image and
   re-runs `musl-source-fixes.sh` so a resumed chain isn't stale. The
   instrumented arm is `CHS_PGO_PHASE=1` through that injection block,
   resumed off the existing r12 — no setup edit, no refetch, no repatch.
   Revised shape: one no-LTO warm ninja (still a full Blink+v8+content
   relink since FDO changes every TU's codegen, but skips the cold chain's
   front half) + a profraw-collection job (minutes) + one normal use build.
   **`is_cfi` must stay ON in the generate arm** — LTO runs after the
   frontend so it never touches the FDO CFG hash, but CFI's type tests ARE
   in that hash ([[project_chromium_pgo_hash_needs_cfi]]); generating with
   it off would just recreate the same mismatch class against our OWN
   profile instead of Google's. Amortises across chromium milestones (~6
   weeks), not per round — every other dispatch just consumes the profdata,
   same as it consumes Google's today. Go/no-go should be measured off the
   no-LTO ninja's actual time against existing chain timings, not arithmetic.

3. **Workload-driver design resolved.** `runtime-probe.cjs`'s own kernels
   ARE the workload (no chromium-upstream `tools/pgo/generate_profile.py`
   telemetry-benchmark equivalent needed). Mechanics: `LLVM_PROFILE_FILE=
   /out/prof/%p-%m.profraw` (headless_shell is multi-process — without
   `%p` the renderers clobber each other's profraw), `--no-sandbox` so
   child processes can write, then `llvm-profdata merge` over the
   directory. **Stated caveat, not yet resolved either way:** this is
   training on the test — defensible for an image whose only job is
   running Playwright, but it makes any claim about general-browsing perf
   worthless. Say it before the numbers exist, not after.

**Unclaimed mirror-image lever on firefox, tested first because it's
cheap.** FF self-generates its profile but trains on Mozilla's own `mach`
profileserver corpus, not our probe kernels — if "train on the graded
workload" is the real argument, FF is the cheap place (6h05, already
plumbed) to test whether it's true at all before spending chromium's ~60h.
See [[project_ff_pgo_corpus_append_experiment]] for that run.

Still gated on part 5b of run `35909301424` (does `-fprofile-generate`
link/run/merge at all under musl+clang23) before dispatching anything.

**2026-09-23, run `35909301424` finished — both verdicts in, and 5a
overturns the premise this file opened with.**

5a (CFG-shaping flags, recompiled the 4 residual TUs once per absent
flag): no absent flag closes any mismatch and `-fsanitize=cfi-mfcall`
*widens* it (3 fns / 5.46M counts dropped vs baseline's 2/0). But the
bigger read is the baseline table itself, taken against the
CFI+snapshot-clang chain ([[project_chromium_pgo_hash_needs_cfi]]'s
shipped PR #273 toolchain) instead of the packaged clang the original
"18 mismatched functions" figure was measured on:

| dir | profiled | mismatch | fn% | counts dropped | cnt% |
|---|---|---|---|---|---|
| core/layout | 1474 | 3 | 0.2% | 0 | 0.0% |
| core/dom | 2849 | 2 | 0.1% | 0 | 0.0% |
| core/css | 1373 | 5 | 0.4% | 3130 | 0.0% |
| platform | 217 | 2 | 0.9% | 4101 | 0.0% |
| base | 218 | 0 | 0.0% | 0 | 0.0% |

`residual TUs: 4 of 4 resolved`, **0.0% of counts dropped**. The old
picture this file's §"Why chromium's PGO gap is structurally different"
was built on — `Element::AttributeChanged` 62M / `RecalcOwnStyle` 19M /
`PseudoStateChanged` 10M counts lost — was measured pre-snapshot-clang
and is gone on the current toolchain: **Google's borrowed profile now
applies almost whole.** The foreign-hash argument for chromium self-PGO
is dead. What's left to justify it is workload fit only (Google's
browsing corpus vs our own probe kernels), exactly what
[[project_ff_pgo_corpus_append_experiment]] tests on Firefox first —
self-PGO stays undispatched, now gated on that result rather than on 5b.

5b: mechanically clear anyway — `OK: link + run + llvm-profdata merge
(744 bytes)`, clang 23, `libclang_rt.profile-x86_64.a` present. Doesn't
matter for the go/no-go now that 5a killed the rationale.

**RESOLVED 2026-09-24 — the Firefox gate answered workload fit, and it's a
wash.** [[project_ff_pgo_corpus_append_experiment]]'s retrain came back
ratchet geomean 0.995 then 1.001 over two draws, breaching a different row
each time inside that row's own cv — not a lever. Self-PGO chromium has now
lost both rationales it ever had: foreign-hash mismatch (0.0% counts
dropped, above) and workload fit (tested as directly as it can be, on
Firefox, here). Recommendation: drop the self-PGO lever rather than spend
the chromium round pricing it — nothing measured left to justify the
dispatch. Left open for chromium parity: `-march=x86-64-v3`, untried, see
[[project_chromium_residual_gap_candidates]]'s 2026-09-24 entry.

Same run also closed a dead lever: **stack-clash protection is
confirmed to emit zero probes on both ours and official** (`.text`
160,447,270 vs 161,907,689) — nothing to remove there either.

**How to apply:** don't cite the "18 hot functions mismatch" figure for
chromium PGO going forward — it was a pre-snapshot-clang artifact of a
toolchain since replaced. Re-derive residual-TU counts against whatever
chain is currently shipped before reasoning about PGO hash mismatches.
