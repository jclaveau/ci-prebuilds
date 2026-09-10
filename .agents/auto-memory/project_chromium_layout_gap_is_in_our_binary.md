---
name: project_chromium_layout_gap_is_in_our_binary
description: normalised perf-record DSO split says 88-92% of chromium's layout gap is inside our own chrome-headless-shell and only 6-10% is libc — musl memset is the single largest resolved leaf, both binaries are stripped so nothing finer is attributable, and the PMU was refused so the IPC question is still open
metadata:
  type: project
---

Run 34404854007, consumer image vs official, `layout_boxonly` / `layout_reflow`
/ `layout_text`, 100 s steady state per kernel per arm.

**Normalise the DSO shares onto a common time base before reading them.** perf
reports share-of-samples *within one arm*, so two 93% figures are not equal
amounts of work when one arm's total is 1.34x the other's. Multiply our shares
by the measured ratio first:

| kernel | ratio | main binary | libc | libc share of gap |
|---|---|---|---|---|
| `layout_boxonly` | 1.336 | 1.246 vs 0.950 = **1.31x** | 0.057 vs 0.023 | +3.4 of 33.6 pts = **10%** |
| `layout_reflow` | 1.276 | 1.189 vs 0.934 = **1.27x** | 0.030 vs 0.012 | +1.8 of 27.6 pts = **6%** |

So the layout gap is **codegen in our own binary**, not libc. That is sharper
than the earlier "musl ~19%" reading and it retires libc as the layout lead —
`memset` is the largest resolved leaf at 3.95% of our samples, and even
attributing ALL of official's libc to memset leaves it worth ~3 points.

**Both binaries are stripped**, so nothing finer is attributable: ours is built
`symbol_level = 0` and official ships stripped too, and every hot entry in the
`--sort dso,sym` report is a bare address on both sides. Resolving the 90% needs
symbols from the same build — the round images keep `obj/`, so a symbolised
`chrome-headless-shell` is recoverable without a rebuild, but it is plumbing
that does not exist yet.

**The PMU was refused on this runner** — `cycles`, `stalled-cycles-frontend` and
`L1-icache-load-misses` all came back "not supported", the failure mode
[[project_chromium_perf_record_first_read]] warns about. So the +16%
instructions / -13% IPC split is still unexplained and frontend-vs-backend is
still undecided. Software counters (`task-clock`, faults) did populate.

**`layout_text` is not a clean comparison.** Its checksums DIFFER between arms
(3837212 ours, 4085642 official) while `layout_boxonly` and `layout_reflow`
match exactly — the font mismatch means the two arms lay out different text, so
that row compares two renderings, not two speeds. Quote the box kernels.
See [[project_probe_font_mismatch_confounds_layout]].
