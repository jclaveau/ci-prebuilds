---
name: project_wk_pgo_corpus_widening_dispositioned
description: 2026-09-24 — chromium's own PGO corpus is a 4-benchmark Telemetry/crossbench mix (speedometer3, jetstream3, system_health, motionmark), not a page list; mapped onto WebKit's upstream PerformanceTests, Speedometer3 doesn't exist there and JetStream2 is the only unskipped analog; decided NOT to touch candidate A (perf/wk-pgo) now, and candidate B (perf/wk-pgo-corpus, cancelled) would not have trained JetStream2 either
metadata:
  type: project
---

Grew out of jean asking whether chromium ships a PGO-corpus-regeneration
script, in the middle of watching [[project_wk_pgo_multidso_sigbus_percent_m]]
redispatch.

**Chromium's own corpus mechanics** (`tools/pgo/generate_profile.py`,
in-tree upstream, `python3 tools/pgo/generate_profile.py -C out/builddir`):
the corpus is graded **benchmarks**, not a hand-picked page list —
`speedometer3.crossbench` always, `jetstream3.crossbench` (skipped on
win-x86), `system_health` (desktop), `motionmark` variants
(mobile/desktop). Profraw handling faces the identical collision class this
repo hit on WebKit: `LLVM_PROFILE_FILE = f'{raw_path}/default-%2m.profraw'`
— `%m` with a `2`-pool cap, capping the file count instead of one-per-image.
No `%c`: chromium's runs end cleanly (unlike the WK corpus run, which is
killed by `timeout -s TERM`), so it never needs continuous mode. Merge is
plain `llvm-profdata merge`. Two corpus-adjacent knobs stay internal-only:
builder configs (`internal/infra/config/.../chrome.pgo.star`) and trybot
profiles in GCS `chrome-pgo-trybot-profiles`, selected per-platform by
`chrome/build/<arch>.pgo.txt`. **We use none of this** — `apply-and-build.sh:562`
pins `pgo_data_path` to Google's public profile precisely to skip
`tools/update_pgo_profiles.py` (wants depot_tools + gsutil); gn only invokes
that script when `pgo_data_path` is empty. So our chromium eats Google's
profile, itself trained on this same 4-benchmark mix — confirms the
"borrowed profile, foreign corpus" framing in
[[project_chromium_three_levers_dispatched_parallel]] with the actual
recipe behind "Google's browsing corpus".

**Mapped onto WebKit's upstream `PerformanceTests/`** (queried
`WebKit/WebKit` at main):

| chromium benchmark | WK analog | present | skipped |
|---|---|---|---|
| speedometer3 | Speedometer3 | **no** — not vendored upstream | — |
| (its narrower predecessor) | Speedometer2.1 | yes | listed in `Skipped` (`index.html`) |
| — | StyleBench | yes | only `InteractiveRunner.html` |
| jetstream3 | JetStream (1) | yes | **skipped** |
| jetstream3 | **JetStream2** | yes | **not skipped** — the real analog |
| motionmark | MotionMark | yes | **skipped** |
| system_health | — | no analog | — |
| — | Octane, SunSpider | yes | not skipped (ARES-6 is) |

So: `jetstream3` → `JetStream2` is a real, already-in-tree analog;
`speedometer3` has no analog (2.1 is the closest, already candidate A's
corpus); `motionmark`/`system_health` have no live counterpart. Adding
Speedometer 3 itself would mean vendoring `WebKit/Speedometer` as a new
external fetch — not worth it while 2.1 is in-tree and untested for value.

**Why JetStream2 specifically would matter:** WK's weakest rows vs official
are `js_alloc` (1.00–1.03) and `libm_fmod`. Speedometer2.1 is DOM/layout-
dominated, so JSC's upper JIT tiers get little training from it; JetStream2
is pure JSC and would be the one corpus addition that could move `js_alloc`.
(`libm_fmod` is musl's fmod, not codegen — PGO can't reach it, already
answered by [[project_wk_fastfmod_ships]].) Real cost: JetStream2 doesn't
use `benchmark-report.js`, so candidate A's `startFunction: 'startTest'`
wiring won't drive it — it has its own driver needing its own entry point.

**Decision: do not touch candidate A (`perf/wk-pgo`) now.** Two reasons: (1)
A's question is "does WK PGO do anything at all" against a baseline of *no
profile* — widening the corpus in the same candidate confounds that
variable with corpus breadth. (2) Editing `train.html` changes the source
sha → new `wk-wpe-*-sha-*` lineage → Phase 0 restarts cold, discarding
whatever's in flight (at decision time, 1h20 into the `%m`-fix rerun).

**Candidate B, if ever resumed, needs redesigning — it does not train
JetStream2 either.** Its deep entries are only `Speedometer2.1` and
`StyleBench`; its flat walk covers WebKit's own micro-pages (Layout, DOM,
CSS, Canvas, Paint, Bindings, SVG, ShadowDOM, Animation, Containment,
Interactive, Intl, Media, Mutation) — broad over WebKit's internals, not
broad over graded benchmarks. That's the opposite shape from chromium's
corpus (4 benchmarks) and from what would actually target `js_alloc`.
Already cancelled per jean ("need to work on other projects") and carries
the pre-`%m`-fix SIGBUS bug on top ([[project_wk_pgo_multidso_sigbus_percent_m]]).

**How to apply:** if WK PGO corpus-widening ever gets picked back up, the
next real experiment is "add a JetStream2 deep entry to candidate A once it
ships", not resurrecting candidate B as written — B's page-breadth strategy
was never the same idea as chromium's benchmark-breadth one, and its own
gate would answer "does JS-tier training help" no better than the current
Speedometer2.1-only corpus does.
