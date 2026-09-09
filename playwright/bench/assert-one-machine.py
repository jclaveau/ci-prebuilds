#!/usr/bin/env python3
"""Fail unless every arm of a probe JOB was measured on ONE machine.

The alpine/official ratio is runner-dependent — the same webkit reads
`libm_fmod` 5.35 on an EPYC 7763, 6.3 on a 9V74 and 7.65 on a Xeon 8370C, at a
within-class CV of 0.5%. perf-probe.yml therefore runs every arm of a draw
inside a single job, which puts them on one machine by construction.

"By construction" is exactly the kind of claim that quietly stops being true,
so this asserts it from the artifacts instead: each run records `runner.cpu`,
and a job whose runs disagree is not a comparison.

The unit is the job, not the browser. A browser is deliberately drawn several
times per run — that is how the fleet gets sampled for a CPU model — so its
draws land on different machines on purpose, and each artifact keeps its own
directory to stay separable. Grouping by browser here would fail the very
sampling it exists to protect.

usage: assert-one-machine.py <dir-of-probe-json>
"""

import collections
import json
import pathlib
import sys


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "perf-current")
    cpus: dict[str, set[str]] = collections.defaultdict(set)
    for path in sorted(root.rglob("*.json")):
        with open(path) as fh:
            doc = json.load(fh)
        cpu = (doc.get("runner") or {}).get("cpu")
        if not cpu or not doc.get("browser"):
            continue
        # One directory per downloaded artifact, and one artifact per job.
        job = str(path.parent.relative_to(root)) or "."
        cpus[job].add(cpu)

    if not cpus:
        print(f"::error::no probe JSON with a runner.cpu under {root}")
        return 1

    bad = 0
    for job, models in sorted(cpus.items()):
        if len(models) > 1:
            print(f"::error::{job} was measured across {len(models)} CPU "
                  f"models, so its arms are not comparable: "
                  f"{', '.join(sorted(models))}")
            bad = 1
        else:
            print(f"ok: {job} on {next(iter(models))}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
